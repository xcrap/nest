import Foundation
import Combine

/// One status refresh: which services run and each project's state, keyed by project ID.
public struct ServiceStatusSnapshot: Sendable {
    public var frankenphp: Bool
    public var mariadb: Bool
    public var cloudflared: Bool
    public var projects: [String: ProjectRuntimeState]

    public init(frankenphp: Bool, mariadb: Bool, cloudflared: Bool, projects: [String: ProjectRuntimeState] = [:]) {
        self.frankenphp = frankenphp
        self.mariadb = mariadb
        self.cloudflared = cloudflared
        self.projects = projects
    }
}

@MainActor
public final class ProcessController: ObservableObject {
    public enum ProjectOperation: Sendable {
        case starting, stopping
        var label: String { self == .starting ? "Starting" : "Stopping" }
    }

    /// What the controller does to the Mac besides tunnel publication and route probes:
    /// brew services, Caddy, launchd, the process table and PF. `init()` acts on the system;
    /// tests replace each member.
    public struct SystemHooks {
        public var applyCaddy: (AppSettings, [Site], [AppProject], _ running: Bool) async throws -> String
        public var brew: (BrewServiceAction, _ service: String) async throws -> Void
        public var isCaddyRunning: () async -> Bool
        public var isMariaDBRunning: () async -> Bool
        public var stopConnector: () async -> (result: CommandResult, running: Bool)
        public var captureStatus: (AppSettings, [AppProject]) async -> ServiceStatusSnapshot
        public var removeLegacyAgents: () async -> Void
        public var repairPortRedirect: (_ allowPrompt: Bool) async -> PortRedirectRepairOutcome
        public var flushDNSCache: () -> Void
        public var projectLifecycle: @Sendable () -> ProjectLifecycleService
        /// Waits before re-checking a just-published route that is still settling.
        public var routeRetryDelays: [Duration]

        public init() {
            applyCaddy = { try await ConfigurationService.shared.applyCaddy(settings: $0, sites: $1, projects: $2, running: $3) }
            brew = { try await ProcessController.brew($0, service: $1) }
            isCaddyRunning = { await BlockingWork.run { LocalRedirectProbe.isCaddyAdminReachable() } }
            isMariaDBRunning = { await BlockingWork.run { ProcessController.processExists("mariadbd") } }
            stopConnector = {
                await BlockingWork.run {
                    let result = LaunchAgentService.stop(label: ProcessController.cloudflaredLaunchAgentLabel)
                    return (result, LaunchAgentService.isRunning(label: ProcessController.cloudflaredLaunchAgentLabel))
                }
            }
            captureStatus = { _, projects in await BlockingWork.run { ProcessController.captureStatus(projects: projects) } }
            removeLegacyAgents = { await BlockingWork.run { ProcessController.removeLegacyCloudflaredLaunchAgents() } }
            repairPortRedirect = { allowPrompt in
                await BlockingWork.run(qos: .userInitiated) { ProcessController.restorePortRedirect(allowPrompt: allowPrompt) }
            }
            flushDNSCache = { ProcessController.flushDNSCache() }
            projectLifecycle = { ProjectLifecycleService() }
            routeRetryDelays = [.seconds(2), .seconds(5), .seconds(10)]
        }
    }

    @Published public var frankenphpRunning = false
    @Published public var mariadbRunning = false
    @Published public var cloudflaredRunning = false
    @Published public var frankenphpError: String?
    @Published public var mariadbError: String?
    @Published public var cloudflaredError: String?
    @Published public private(set) var projectStatuses: [String: Bool] = [:]
    @Published public private(set) var projectErrors: [String: String] = [:]
    @Published public private(set) var projectOperations: [String: ProjectOperation] = [:]
    @Published public private(set) var serviceOperations: Set<String> = []
    @Published public var caddyApplyState: ApplyState = .unverified
    @Published public var tunnelApplyState: ApplyState = .unverified
    @Published public private(set) var routeHealth: [String: RouteHealth] = [:]
    @Published public private(set) var refreshingDNS = false
    @Published public private(set) var dnsRefreshError: String?
    private var refreshTask: Task<Void, Never>?
    private var caddyTask: Task<Void, Never>?
    private var tunnelTask: Task<Void, Never>?
    private var queuedTunnel: TunnelRequest?
    /// A connector stop requested while an apply was in flight; it runs once that finishes.
    private var cloudflaredStopQueued = false
    /// Edits to a project that was busy starting or stopping, applied once it settles.
    private var queuedRestarts: [String: (previous: AppProject, updated: AppProject)] = [:]
    private var healthGeneration = UUID()
    private var healthChecks: [String: UUID] = [:]
    private var healthTasks: [String: Task<Void, Never>] = [:]
    private let applyTunnel: TunnelApply
    private let probeRoute: (String) async -> RouteHealth
    private let refreshDNS: () async throws -> Void
    private let hooks: SystemHooks
    private var didRemoveLegacyAgents = false
    /// The administrator prompt for PF was declined, or could not help, this session.
    private var portRedirectPromptSuppressed = false
    /// Kept in `frankenphpError` while the 80/443 redirect is known to be broken.
    private var portRedirectError: String?
    private var runStateErrors: [String: RunStateError] = [:]

    public typealias TunnelApply = (AppSettings, [TunnelRoute], [Site], [AppProject], Bool, Bool) async throws -> String
    private struct TunnelRequest {
        var settings: AppSettings
        var routes: [TunnelRoute]
        var sites: [Site]
        var projects: [AppProject]
        var push: Bool
        var start: Bool
    }
    /// Bumped whenever a start/stop begins or ends. A status snapshot taken before the
    /// latest change is stale and must not overwrite the operation's own result.
    private var stateGeneration = 0
    private var isRestoringNetwork = false

    /// Only what reaches cloudflared counts: unrelated site or settings edits leave tunnels applied.
    private struct TunnelInput: Equatable {
        var rendered: String
        var cloudflare: CloudflareSettings
        var binary: String
        var log: String

        init(settings: AppSettings, routes: [TunnelRoute], sites: [Site], projects: [AppProject]) {
            rendered = TunnelConfigRenderer(settings: settings.cloudflareSettings).render(routes: routes, sites: sites, projects: projects)
            cloudflare = settings.cloudflareSettings
            binary = settings.runtimePaths.cloudflaredBinary
            log = settings.runtimePaths.cloudflaredLog
        }
    }
    private var desiredTunnelInput: TunnelInput?

    /// What a Caddy apply is built from: running sites and projects with a local domain.
    private struct CaddyRequest {
        var settings: AppSettings
        var sites: [Site]
        var projects: [AppProject]
    }

    /// Compared by rendered output, so renaming a stopped site or editing a project's command
    /// leaves Caddy applied.
    private struct CaddyInput: Equatable {
        var rendered: String
        var directory: String
        var binary: String

        init(_ request: CaddyRequest) {
            let settings = request.settings
            rendered = ConfigRenderer(configDirectory: settings.caddyConfigDirectory, frankenphpLogPath: settings.runtimePaths.frankenphpLog)
                .render(sites: request.sites, projects: request.projects)
            directory = settings.caddyConfigDirectory
            binary = settings.runtimePaths.frankenphpBinary
        }
    }
    private var appliedCaddyInput: CaddyInput?

    /// An error about whether a service runs ("did not start", "is still running") stops being
    /// true once a refresh sees the opposite state. Configuration errors stay until the next apply.
    private struct RunStateError {
        var message: String
        var clearsWhenRunning: Bool
    }

    // App actions use these store-aware entry points. Raw snapshots below also support
    // isolated controller tests, but cannot distinguish an empty list from a failed read.
    public func markCaddyPending(store: SiteStore) {
        guard canConfigureCaddy(store) else { return }
        markCaddyPending(settings: store.settings, sites: store.sites, projects: store.appProjects)
    }

    public func applyCaddy(store: SiteStore) {
        guard canConfigureCaddy(store) else { return }
        applyCaddy(settings: store.settings, sites: store.sites, projects: store.appProjects)
    }

    public func startFrankenPHP(store: SiteStore) {
        guard canConfigureCaddy(store) else { return }
        startFrankenPHP(settings: store.settings, sites: store.sites, projects: store.appProjects)
    }

    public func markTunnelsPending(store: SiteStore, automaticallyApply: Bool = false) {
        guard canConfigureTunnels(store) else { return }
        markTunnelsPending(settings: store.settings, routes: store.tunnelRoutes, sites: store.sites,
                           projects: store.appProjects, automaticallyApply: automaticallyApply)
    }

    public func applyTunnels(store: SiteStore, push: Bool? = nil, start: Bool = false) {
        guard canConfigureTunnels(store) else { return }
        applyTunnels(settings: store.settings, routes: store.tunnelRoutes, sites: store.sites,
                     projects: store.appProjects, push: push, start: start)
    }

    private func canConfigureCaddy(_ store: SiteStore) -> Bool {
        guard let error = store.caddyConfigurationError else { return true }
        frankenphpError = error
        caddyApplyState = .failed(error)
        return false
    }

    private func canConfigureTunnels(_ store: SiteStore) -> Bool {
        guard let error = store.tunnelConfigurationError else { return true }
        cloudflaredError = error
        tunnelApplyState = .failed(error)
        return false
    }

    public func markTunnelsPending(settings: AppSettings, routes: [TunnelRoute], sites: [Site], projects: [AppProject], automaticallyApply: Bool = false) {
        let input = TunnelInput(settings: settings, routes: routes, sites: sites, projects: projects)
        guard desiredTunnelInput != input else { return }
        let firstObservation = desiredTunnelInput == nil && !automaticallyApply
        desiredTunnelInput = input
        resetRouteHealth()
        if !isServiceBusy("Cloudflared") { tunnelApplyState = firstObservation ? .unverified : .pending }
        if automaticallyApply, AppSettings.reviewDirectory == nil {
            applyTunnels(settings: settings, routes: routes, sites: sites, projects: projects,
                         push: settings.cloudflareSettings.hasAPIConfiguration, start: routes.contains(where: \.active))
        }
    }

    public func markCaddyPending(settings: AppSettings, sites: [Site], projects: [AppProject]) {
        let request = CaddyRequest(settings: settings, sites: sites, projects: projects)
        guard CaddyInput(request) != appliedCaddyInput, !caddyApplyState.isBusy else { return }
        caddyApplyState = .pending
    }

    private var queuedCaddy: CaddyRequest?

    public nonisolated static var cloudflaredLaunchAgentLabel: String {
        "app.nest.\(AppSettings.storageRootName.replacingOccurrences(of: ".", with: "-")).cloudflared"
    }
    public nonisolated static let legacyCloudflaredLaunchAgentLabels = ["app.nest.cloudflared"]
    public init(applyTunnel: @escaping TunnelApply = { settings, routes, sites, projects, running, push in
        try await ConfigurationService.shared.applyTunnel(settings: settings, routes: routes, sites: sites, projects: projects,
            running: running, push: push, restart: { try await ProcessController.restartConnector(settings: settings) })
    }, probeRoute: @escaping (String) async -> RouteHealth = { await RouteHealthService().check(hostname: $0) },
       refreshDNS: @escaping () async throws -> Void = { try await RouteHealthService.refreshMacDNS() },
       hooks: SystemHooks = SystemHooks()) {
        self.applyTunnel = applyTunnel
        self.probeRoute = probeRoute
        self.refreshDNS = refreshDNS
        self.hooks = hooks
    }

    public func isServiceBusy(_ service: String) -> Bool { serviceOperations.contains(service) }

    /// @Published notifies on every assignment; skip no-op writes so views don't redraw each refresh.
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ProcessController, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func beginOperation(_ service: String) {
        serviceOperations.insert(service)
        stateGeneration += 1
    }

    private func endOperation(_ service: String) {
        serviceOperations.remove(service)
        stateGeneration += 1
    }

    // MARK: - Service errors

    private func errorKeyPath(_ service: String) -> ReferenceWritableKeyPath<ProcessController, String?> {
        switch service {
        case "FrankenPHP": return \.frankenphpError
        case "MariaDB": return \.mariadbError
        default: return \.cloudflaredError
        }
    }

    private func setRunStateError(_ service: String, _ message: String, clearsWhenRunning: Bool) {
        runStateErrors[service] = RunStateError(message: message, clearsWhenRunning: clearsWhenRunning)
        self[keyPath: errorKeyPath(service)] = message
    }

    private func resolveRunStateError(_ service: String, running: Bool) {
        guard let error = runStateErrors[service] else { return }
        let keyPath = errorKeyPath(service)
        // Replaced by another error since: that one is not this mechanism's to clear.
        guard self[keyPath: keyPath] == error.message else { runStateErrors[service] = nil; return }
        guard running == error.clearsWhenRunning else { return }
        runStateErrors[service] = nil
        if service == "FrankenPHP" { clearFrankenPHPError() } else { self[keyPath: keyPath] = nil }
    }

    /// Successful FrankenPHP work clears its error, except a known-broken 80/443 redirect.
    private func clearFrankenPHPError() { frankenphpError = portRedirectError }

    private func setPortRedirectError(_ message: String?) {
        if let message { frankenphpError = message }
        else if portRedirectError != nil, frankenphpError == portRedirectError { frankenphpError = nil }
        portRedirectError = message
    }

    // MARK: - FrankenPHP / Caddy

    public func applyCaddy(settings: AppSettings, sites: [Site], projects: [AppProject]) {
        queuedCaddy = CaddyRequest(settings: settings, sites: sites, projects: projects)
        runQueuedCaddy()
    }

    /// Whether Caddy can be reloaded depends on FrankenPHP running, so while it starts or stops,
    /// requests wait and the newest one is applied once that settles.
    private func runQueuedCaddy() {
        guard caddyTask == nil, !isServiceBusy("FrankenPHP"), let request = queuedCaddy else { return }
        if isApplied(CaddyInput(request)) { queuedCaddy = nil; return }
        caddyTask = Task {
            while !isServiceBusy("FrankenPHP"), let request = queuedCaddy {
                queuedCaddy = nil
                let input = CaddyInput(request)
                // Identical output (e.g. renaming a stopped site): nothing to validate, write or reload.
                if isApplied(input) { continue }
                caddyApplyState = .applying
                do {
                    let message = try await hooks.applyCaddy(request.settings, request.sites, request.projects, frankenphpRunning)
                    clearFrankenPHPError()
                    appliedCaddyInput = input
                    caddyApplyState = .applied(message)
                } catch {
                    frankenphpError = error.localizedDescription
                    caddyApplyState = .failed(error.localizedDescription)
                }
            }
            caddyTask = nil
        }
    }

    private func isApplied(_ input: CaddyInput) -> Bool {
        guard input == appliedCaddyInput, case .applied = caddyApplyState else { return false }
        return true
    }

    /// Ends a FrankenPHP start/stop and applies what was requested meanwhile, now that it is
    /// known whether Caddy runs.
    private func finishFrankenPHPOperation() {
        endOperation("FrankenPHP")
        runQueuedCaddy()
    }

    public func startFrankenPHP(settings: AppSettings, sites: [Site], projects: [AppProject]) {
        guard !isServiceBusy("FrankenPHP") else { return }
        beginOperation("FrankenPHP")
        caddyApplyState = .applying
        // This snapshot supersedes earlier requests; requests from now on wait for the start.
        queuedCaddy = nil
        Task {
            // A site toggle may be applying right now: start after it instead of dropping the request.
            while let pending = caddyTask { await pending.value }
            var request = CaddyRequest(settings: settings, sites: sites, projects: projects)
            if let newer = queuedCaddy { request = newer; queuedCaddy = nil }
            caddyApplyState = .applying
            do {
                _ = try await hooks.applyCaddy(request.settings, request.sites, request.projects, frankenphpRunning)
                appliedCaddyInput = CaddyInput(request)
            } catch {
                frankenphpError = error.localizedDescription
                caddyApplyState = .failed(error.localizedDescription)
                finishFrankenPHPOperation()
                return
            }
            do {
                if !frankenphpRunning {
                    try await hooks.brew(.start, "frankenphp")
                    guard await waitForCaddy() else { throw ConfigurationFailure("FrankenPHP did not become ready. Check its log.") }
                }
                frankenphpRunning = true
                clearFrankenPHPError()
                caddyApplyState = .applied("Applied to Caddy")
            } catch {
                setRunStateError("FrankenPHP", error.localizedDescription, clearsWhenRunning: true)
                caddyApplyState = .failed(error.localizedDescription)
            }
            finishFrankenPHPOperation()
            if frankenphpRunning { restoreSystemRulesIfNeeded() }
        }
    }

    public func stopFrankenPHP() { stopBrew("frankenphp", displayName: "FrankenPHP") }
    public func stopMariaDB() { stopBrew("mariadb", displayName: "MariaDB") }
    private func stopBrew(_ name: String, displayName: String) {
        guard !isServiceBusy(displayName) else { return }
        beginOperation(displayName)
        let isFrankenPHP = name == "frankenphp"
        Task {
            // Let an in-flight Caddy apply finish while Caddy can still accept its reload;
            // otherwise the reload fails and the previous Caddyfile is restored.
            if isFrankenPHP { while let pending = caddyTask { await pending.value } }
            do {
                try await hooks.brew(.stop, name)
                let stillRunning: Bool
                if isFrankenPHP { stillRunning = await hooks.isCaddyRunning() }
                else { stillRunning = await hooks.isMariaDBRunning() }
                if isFrankenPHP {
                    frankenphpRunning = stillRunning
                    if stillRunning {
                        setRunStateError(displayName, "An externally managed FrankenPHP/Caddy instance is still running.", clearsWhenRunning: false)
                    } else {
                        setPortRedirectError(nil)
                        frankenphpError = nil
                        caddyApplyState = .unverified
                    }
                } else {
                    mariadbRunning = stillRunning
                    if stillRunning {
                        setRunStateError(displayName, "An externally managed MariaDB instance is still running.", clearsWhenRunning: false)
                    } else {
                        mariadbError = nil
                    }
                }
            } catch {
                setRunStateError(displayName, error.localizedDescription, clearsWhenRunning: false)
            }
            if isFrankenPHP { finishFrankenPHPOperation() } else { endOperation(displayName) }
        }
    }

    public func startMariaDB(serverBinary: String) {
        guard !isServiceBusy("MariaDB") else { return }
        guard !serverBinary.isEmpty else {
            mariadbError = "Set the MariaDB server path in Settings → Paths first."
            return
        }
        beginOperation("MariaDB")
        Task {
            defer { endOperation("MariaDB") }
            do {
                guard FileManager.default.isExecutableFile(atPath: serverBinary) else { throw ConfigurationFailure("MariaDB binary is not executable at \(serverBinary).") }
                try await hooks.brew(.start, "mariadb")
                var ready = false
                for _ in 0..<20 {
                    if await hooks.isMariaDBRunning() { ready = true; break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard ready else { throw ConfigurationFailure("MariaDB did not start. Check its log.") }
                mariadbRunning = true
                mariadbError = nil
            } catch { setRunStateError("MariaDB", error.localizedDescription, clearsWhenRunning: true) }
        }
    }

    // MARK: - Cloudflared

    public func applyTunnels(settings: AppSettings, routes: [TunnelRoute], sites: [Site], projects: [AppProject], push: Bool? = nil, start: Bool = false) {
        desiredTunnelInput = TunnelInput(settings: settings, routes: routes, sites: sites, projects: projects)
        resetRouteHealth()
        var request = TunnelRequest(settings: settings, routes: routes, sites: sites, projects: projects,
                                    push: push ?? settings.cloudflareSettings.hasAPIConfiguration, start: start)
        // Coalesce with a request still waiting without losing what it asked for: a newer edit
        // must not cancel an earlier Start or Cloudflare push.
        if let waiting = queuedTunnel {
            request.push = request.push || waiting.push
            request.start = request.start || waiting.start
        }
        queuedTunnel = request
        if start { cloudflaredStopQueued = false }
        runQueuedTunnels()
    }

    /// A connector stop in progress goes first; it resumes the queue when it finishes.
    private func runQueuedTunnels() {
        guard tunnelTask == nil, !isServiceBusy("Cloudflared"), queuedTunnel != nil else { return }
        tunnelApplyState = .applying
        beginOperation("Cloudflared")
        tunnelTask = Task {
            // Coalesce rapid saves, but finish each remote write before starting the next.
            // A slow older push must never overwrite the user's latest edit.
            while let job = queuedTunnel {
                queuedTunnel = nil
                tunnelApplyState = .applying
                let input = TunnelInput(settings: job.settings, routes: job.routes, sites: job.sites, projects: job.projects)
                let shouldRun = job.start || cloudflaredRunning
                do {
                    let message = try await applyTunnel(job.settings, job.routes, job.sites, job.projects, shouldRun, job.push)
                    cloudflaredRunning = shouldRun
                    cloudflaredError = nil
                    let status = job.push ? "Published • DNS and routes synced"
                        : (job.settings.cloudflareSettings.hasAPIConfiguration ? message : "\(message) • Cloudflare API not configured")
                    tunnelApplyState = desiredTunnelInput == input ? .applied(status) : .pending
                    if queuedTunnel == nil, desiredTunnelInput == input {
                        for route in job.routes where route.active { checkRoute(route, retry: true) }
                    }
                } catch {
                    cloudflaredError = error.localizedDescription
                    tunnelApplyState = .failed(error.localizedDescription)
                }
            }
            tunnelTask = nil
            endOperation("Cloudflared")
            if cloudflaredStopQueued {
                cloudflaredStopQueued = false
                stopCloudflared()
            }
        }
    }

    public func stopCloudflared() {
        if tunnelTask != nil {
            // Stop once the apply in flight finishes instead of dropping the request. A queued
            // apply still saves the latest routes, but no longer starts the connector.
            cloudflaredStopQueued = true
            queuedTunnel?.start = false
            return
        }
        guard !isServiceBusy("Cloudflared") else { return }
        beginOperation("Cloudflared")
        Task {
            let (result, running) = await hooks.stopConnector()
            cloudflaredRunning = running
            if result.status == 0 || !running {
                cloudflaredError = nil
            } else {
                setRunStateError("Cloudflared", "Could not stop connector: \(result.output)", clearsWhenRunning: false)
            }
            if !running { tunnelApplyState = .unverified }
            endOperation("Cloudflared")
            runQueuedTunnels()
        }
    }

    public nonisolated static func restartConnector(settings: AppSettings) async throws {
        let result = await BlockingWork.run(qos: .userInitiated) {
            LaunchAgentService.start(connectorDefinition(settings: settings))
        }
        guard result.status == 0 else { throw ConfigurationFailure("Connector restart failed: \(result.output)") }
        for _ in 0..<20 {
            let running = await BlockingWork.run { LaunchAgentService.isRunning(label: cloudflaredLaunchAgentLabel) }
            if running {
                // A process that immediately exits is not a successful restart.
                try await Task.sleep(for: .seconds(1))
                if await BlockingWork.run({ LaunchAgentService.isRunning(label: cloudflaredLaunchAgentLabel) }) { return }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ConfigurationFailure("Connector exited after restart. Check the Cloudflared log.")
    }

    public nonisolated static func connectorDefinition(settings: AppSettings) -> LaunchAgentDefinition {
        LaunchAgentDefinition(label: cloudflaredLaunchAgentLabel,
            programArguments: [settings.runtimePaths.cloudflaredBinary, "--config", settings.cloudflareSettings.configPath, "tunnel", "run", settings.cloudflareSettings.tunnelName],
            standardOutPath: settings.runtimePaths.cloudflaredLog, standardErrorPath: settings.runtimePaths.cloudflaredLog)
    }

    /// Agents from before 0.12 (`app.nest.cloudflared`) keep a duplicate connector alive at login.
    public nonisolated static func removeLegacyCloudflaredLaunchAgents() {
        for label in legacyCloudflaredLaunchAgentLabels where label != cloudflaredLaunchAgentLabel {
            if LaunchAgentService.isInstalled(label: label) { _ = LaunchAgentService.stop(label: label) }
        }
    }

    // MARK: - Status

    /// One snapshot answers every project: a handful of process launches per refresh,
    /// however many projects exist. Only port, label and directory are needed, so commands
    /// (and package.json) are not resolved.
    private nonisolated static func captureStatus(projects: [AppProject]) -> ServiceStatusSnapshot {
        let plans = projects.map(ProjectLaunchPlanner.statusPlan)
        let processes = ProcessSnapshot.capture(ports: plans.map(\.port))
        let lifecycle = ProjectLifecycleService(snapshot: processes)
        return ServiceStatusSnapshot(
            frankenphp: LocalRedirectProbe.isCaddyAdminReachable(),
            mariadb: processes.isProcessRunning(named: "mariadbd"),
            cloudflared: processes.runningJobs[cloudflaredLaunchAgentLabel] != nil,
            projects: Dictionary(plans.map { ($0.projectID, lifecycle.state($0)) }, uniquingKeysWith: { _, last in last })
        )
    }

    public func refreshStatusSnapshot(settings: AppSettings, projects: [AppProject]) {
        guard AppSettings.reviewDirectory == nil, refreshTask == nil else { return }
        let generation = stateGeneration
        // The first refresh is where cloudflared's state is first read: retire legacy agents there.
        let removeLegacyAgents = !didRemoveLegacyAgents
        didRemoveLegacyAgents = true
        refreshTask = Task {
            if removeLegacyAgents { await hooks.removeLegacyAgents() }
            let snapshot = await hooks.captureStatus(settings, projects)
            refreshTask = nil
            guard generation == stateGeneration else { return }
            if !isServiceBusy("FrankenPHP") {
                assign(\.frankenphpRunning, snapshot.frankenphp)
                if !snapshot.frankenphp, portRedirectError != nil { setPortRedirectError(nil) }
                resolveRunStateError("FrankenPHP", running: snapshot.frankenphp)
            }
            if !isServiceBusy("MariaDB") {
                assign(\.mariadbRunning, snapshot.mariadb)
                resolveRunStateError("MariaDB", running: snapshot.mariadb)
            }
            if !isServiceBusy("Cloudflared") {
                assign(\.cloudflaredRunning, snapshot.cloudflared)
                resolveRunStateError("Cloudflared", running: snapshot.cloudflared)
            }
            var statuses = projectStatuses
            var errors = projectErrors
            for (id, state) in snapshot.projects where projectOperations[id] == nil {
                statuses[id] = state.running
                if let error = state.error { errors[id] = error }
                else if errors[id]?.hasPrefix("Port ") == true { errors[id] = nil }
            }
            assign(\.projectStatuses, statuses)
            assign(\.projectErrors, errors)
        }
    }
    public func refreshProjectStatuses(_ projects: [AppProject]) {
        refreshStatusSnapshot(settings: AppSettings(), projects: projects)
    }

    // MARK: - Projects

    public func startProject(_ project: AppProject) { operateProject(project, start: true) }
    public func stopProject(_ project: AppProject) { operateProject(project, start: false) }
    private func operateProject(_ project: AppProject, start: Bool) {
        let lifecycle = hooks.projectLifecycle
        runProjectOperation(project.id, start ? .starting : .stopping) {
            let plan = ProjectLaunchPlanner.plan(for: project)
            let service = lifecycle()
            return start ? service.start(plan) : service.stop(plan)
        }
    }

    /// Applies an edit to a running project: the old definition (port, command, directory)
    /// is stopped before the new one starts, so nothing keeps serving the old port.
    /// While the project is starting or stopping, the edit is applied once that finishes.
    public func restartProject(from previous: AppProject, to updated: AppProject) {
        guard projectOperations[updated.id] == nil else {
            // Keep the first `previous`: that is the definition actually running.
            queuedRestarts[updated.id] = (queuedRestarts[updated.id]?.previous ?? previous, updated)
            return
        }
        let lifecycle = hooks.projectLifecycle
        runProjectOperation(updated.id, .starting) {
            let service = lifecycle()
            let stopped = service.stop(ProjectLaunchPlanner.plan(for: previous))
            if stopped.running { return stopped }
            return service.start(ProjectLaunchPlanner.plan(for: updated))
        }
    }

    private func runProjectOperation(_ id: String, _ operation: ProjectOperation, _ work: @escaping @Sendable () -> ProjectRuntimeState) {
        guard projectOperations[id] == nil else { return }
        projectOperations[id] = operation
        projectErrors[id] = nil
        stateGeneration += 1
        Task {
            let outcome = await BlockingWork.run(qos: .userInitiated, work)
            finishProjectOperation(id, outcome)
        }
    }

    private func finishProjectOperation(_ id: String, _ outcome: ProjectRuntimeState) {
        projectOperations[id] = nil
        projectStatuses[id] = outcome.running
        projectErrors[id] = outcome.error
        stateGeneration += 1
        // Only a project still running has an old definition to replace; a stopped one picks
        // up the edit on its next start.
        if let queued = queuedRestarts.removeValue(forKey: id), outcome.running {
            restartProject(from: queued.previous, to: queued.updated)
        }
    }

    /// Stops a project before its record is deleted. Returns an error, and leaves the project
    /// in place, if it is still running or its launch agent (which starts at login) remains.
    public func stopProjectForDeletion(_ project: AppProject) async -> String? {
        guard projectOperations[project.id] == nil else { return "\(project.name) is busy. Try again when it finishes." }
        projectOperations[project.id] = .stopping
        projectErrors[project.id] = nil
        stateGeneration += 1
        let lifecycle = hooks.projectLifecycle
        let (outcome, agentRemains) = await BlockingWork.run(qos: .userInitiated) { () -> (ProjectRuntimeState, Bool) in
            let plan = ProjectLaunchPlanner.plan(for: project)
            let service = lifecycle()
            let outcome = service.stop(plan)
            return (outcome, service.hasInstalledAgent(plan))
        }
        // A project being deleted is not restarted with an edit made meanwhile.
        queuedRestarts[project.id] = nil
        finishProjectOperation(project.id, outcome)
        guard !outcome.running, !agentRemains else {
            let message = outcome.error ?? "\(project.name) could not be stopped, so it was not deleted."
            // Also shown on the row, in case the view that asked is gone by now.
            projectErrors[project.id] = message
            return message
        }
        projectStatuses[project.id] = nil
        projectErrors[project.id] = nil
        return nil
    }

    public func isProjectRunning(_ project: AppProject) -> Bool { projectStatuses[project.id] ?? false }
    public func isProjectBusy(_ project: AppProject) -> Bool { projectOperations[project.id] != nil }
    public func projectOperation(for id: String) -> ProjectOperation? { projectOperations[id] }
    public func projectError(for id: String) -> String? { projectErrors[id] }
    public func stopAll() { stopFrankenPHP(); stopMariaDB(); stopCloudflared() }

    // MARK: - Route health

    /// Routes changed: checks still in flight describe the old routes.
    private func resetRouteHealth() {
        healthGeneration = UUID()
        for task in healthTasks.values { task.cancel() }
        healthTasks = [:]
        dnsRefreshError = nil
        assign(\.routeHealth, [:])
    }

    /// Right after publication, DNS may not exist yet and a restarted connector is still
    /// registering: Cloudflare answers 530 (error 1033), 502 or 503 until it has.
    private static func isSettling(_ health: RouteHealth) -> Bool {
        switch health {
        case .dnsPending: return true
        case .httpError(let status): return [404, 502, 503, 530].contains(status)
        default: return false
        }
    }

    /// Publication and manual retries share the same per-route check. Ignore results for
    /// routes edited/deleted while a request was in flight.
    public func checkRoute(_ route: TunnelRoute, retry: Bool = false) {
        let generation = healthGeneration
        let checkID = UUID()
        healthChecks[route.id] = checkID
        healthTasks[route.id]?.cancel()
        routeHealth[route.id] = .checking
        let delays = retry ? hooks.routeRetryDelays : []
        healthTasks[route.id] = Task {
            defer { if healthChecks[route.id] == checkID { healthTasks[route.id] = nil } }
            var result = await probeRoute(route.publicHostname)
            for delay in delays {
                guard Self.isSettling(result) else { break }
                do { try await Task.sleep(for: delay) } catch { return }
                guard generation == healthGeneration, healthChecks[route.id] == checkID else { return }
                result = await probeRoute(route.publicHostname)
            }
            guard generation == healthGeneration, healthChecks[route.id] == checkID else { return }
            routeHealth[route.id] = result
        }
    }

    public var needsDNSRefresh: Bool { routeHealth.values.contains(.macDNS) }

    public func refreshMacDNS(routes: [TunnelRoute]) {
        guard !refreshingDNS else { return }
        refreshingDNS = true
        dnsRefreshError = nil
        let generation = healthGeneration
        Task {
            defer { refreshingDNS = false }
            do {
                try await refreshDNS()
                guard generation == healthGeneration else { return }
                for route in routes where route.active { checkRoute(route) }
            } catch { dnsRefreshError = error.localizedDescription }
        }
    }

    private nonisolated static func brew(_ action: BrewServiceAction, service: String) async throws {
        let result = await SystemProcess.captureAsync(BrewServiceController.brewPath, arguments: ["services", action.rawValue, service], timeout: 120)
        guard result.status == 0 else { throw ConfigurationFailure(result.output) }
    }
    private nonisolated static func processExists(_ name: String) -> Bool {
        SystemProcess.capture("/usr/bin/pgrep", arguments: ["-x", name], timeout: 3).status == 0
    }
    private func waitForCaddy() async -> Bool {
        for _ in 0..<20 {
            if await hooks.isCaddyRunning() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    // MARK: - Network (PF and DNS)

    /// Call once at launch and after wake, not on every window appearance: a broken redirect
    /// may need an administrator prompt to repair.
    public func reconcileSystemNetworkState() {
        guard AppSettings.reviewDirectory == nil else { return }
        Task {
            let running = await hooks.isCaddyRunning()
            if !isServiceBusy("FrankenPHP") { assign(\.frankenphpRunning, running) }
            restoreSystemRulesIfNeeded()
        }
    }
    public func handleSystemWake() { reconcileSystemNetworkState() }

    /// An explicit user retry: may show the administrator prompt again after it was declined.
    public func retryPortRedirectRepair() {
        portRedirectPromptSuppressed = false
        restoreSystemRulesIfNeeded()
    }

    /// Flush DNS cache and restore PF port redirect rules if FrankenPHP is running.
    /// Only one check/repair runs at a time, so wake and launch cannot stack prompts, and a
    /// prompt that was declined (or could not help) is not shown again this session.
    private func restoreSystemRulesIfNeeded() {
        hooks.flushDNSCache()

        guard frankenphpRunning, !isRestoringNetwork else { return }
        isRestoringNetwork = true
        let allowPrompt = !portRedirectPromptSuppressed
        Task {
            let outcome = await hooks.repairPortRedirect(allowPrompt)
            isRestoringNetwork = false
            if outcome.suppressesPrompt { portRedirectPromptSuppressed = true }
            switch outcome {
            case .notNeeded, .repaired:
                setPortRedirectError(nil)
            case .suppressed:
                // Keep the more specific message from the attempt that was declined.
                if portRedirectError == nil { setPortRedirectError(outcome.message) }
            default:
                setPortRedirectError(outcome.message)
            }
        }
    }

    /// Restores the 80/443 → 8080/8443 redirect when FrankenPHP runs but the ports don't reach it.
    /// The privileged helper never prompts. Without it, `pfctl -ef /etc/pf.conf` needs an
    /// administrator prompt, shown only when pf.conf already loads Nest's anchor (otherwise a
    /// reload cannot help) and the user has not declined it this session.
    private nonisolated static func restorePortRedirect(allowPrompt: Bool) -> PortRedirectRepairOutcome {
        guard PFRestorePlanner.decision(frankenphpRunning: true, redirectWorking: LocalRedirectProbe.isRedirectReachingCaddy()) == .reloadPF else {
            return .notNeeded
        }
        let wired = (try? String(contentsOfFile: PFHelperManager.pfConfPath, encoding: .utf8)).map {
            PFRestorePlanner.pfConfLoadsNestAnchor($0, anchorExists: { FileManager.default.fileExists(atPath: $0) })
        } ?? false
        switch PFRestorePlanner.reloadMethod(helperEnabled: PFHelperManager.status == .enabled,
                                             pfConfLoadsAnchor: wired, promptAllowed: allowPrompt) {
        case .helper:
            guard PFHelperManager.kickstart() else { return .helperFailed }
            // launchd throttles the helper (ThrottleInterval 5) and TLS may still be warming up.
            return waitForRedirect(seconds: 8) ? .repaired : .helperFailed
        case .administratorPrompt:
            let result = SystemProcess.capture(
                "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "do shell script \"/sbin/pfctl -ef /etc/pf.conf 2>/dev/null\" with administrator privileges"
                ],
                timeout: 600
            )
            return PFRestorePlanner.promptOutcome(status: result.status, output: result.output,
                                                  redirectWorking: result.status == 0 && waitForRedirect(seconds: 2))
        case .unavailable(let outcome):
            return outcome
        }
    }

    private nonisolated static func waitForRedirect(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            Thread.sleep(forTimeInterval: 0.5)
            if LocalRedirectProbe.isRedirectReachingCaddy() { return true }
        } while Date() < deadline
        return false
    }

    /// Flush macOS DNS cache so .test domains resolve immediately.
    private nonisolated static func flushDNSCache() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        process.arguments = ["-flushcache"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
