import Foundation
import Combine

@MainActor
public final class ProcessController: ObservableObject {
    public enum ProjectOperation: Sendable {
        case starting, stopping
        var label: String { self == .starting ? "Starting" : "Stopping" }
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
    private var healthGeneration = UUID()
    private var healthChecks: [String: UUID] = [:]
    private let applyTunnel: TunnelApply
    private let probeRoute: (String) async -> RouteHealth
    private let refreshDNS: () async throws -> Void

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

    private struct CaddyInput: Equatable {
        var rendered: String
        var directory: String
        var binary: String

        init(settings: AppSettings, sites: [Site]) {
            rendered = ConfigRenderer(configDirectory: settings.caddyConfigDirectory, frankenphpLogPath: settings.runtimePaths.frankenphpLog).render(sites: sites)
            directory = settings.caddyConfigDirectory
            binary = settings.runtimePaths.frankenphpBinary
        }
    }
    private var appliedCaddyInput: CaddyInput?

    // App actions use these store-aware entry points. Raw snapshots below also support
    // isolated controller tests, but cannot distinguish an empty list from a failed read.
    public func markCaddyPending(store: SiteStore) {
        guard canConfigureCaddy(store) else { return }
        markCaddyPending(settings: store.settings, sites: store.sites)
    }

    public func applyCaddy(store: SiteStore) {
        guard canConfigureCaddy(store) else { return }
        applyCaddy(settings: store.settings, sites: store.sites)
    }

    public func startFrankenPHP(store: SiteStore) {
        guard canConfigureCaddy(store) else { return }
        startFrankenPHP(settings: store.settings, sites: store.sites)
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
        healthGeneration = UUID()
        dnsRefreshError = nil
        assign(\.routeHealth, [:])
        if !isServiceBusy("Cloudflared") { tunnelApplyState = firstObservation ? .unverified : .pending }
        if automaticallyApply, AppSettings.reviewDirectory == nil {
            applyTunnels(settings: settings, routes: routes, sites: sites, projects: projects,
                         push: settings.cloudflareSettings.hasAPIConfiguration, start: routes.contains(where: \.active))
        }
    }

    public func markCaddyPending(settings: AppSettings, sites: [Site]) {
        guard CaddyInput(settings: settings, sites: sites) != appliedCaddyInput, !caddyApplyState.isBusy else { return }
        caddyApplyState = .pending
    }

    private var queuedCaddy: (AppSettings, [Site])?

    public nonisolated static var cloudflaredLaunchAgentLabel: String {
        "app.nest.\(AppSettings.storageRootName.replacingOccurrences(of: ".", with: "-")).cloudflared"
    }
    public nonisolated static let legacyCloudflaredLaunchAgentLabels = ["app.nest.cloudflared"]
    public init(applyTunnel: @escaping TunnelApply = { settings, routes, sites, projects, running, push in
        try await ConfigurationService.shared.applyTunnel(settings: settings, routes: routes, sites: sites, projects: projects,
            running: running, push: push, restart: { try await ProcessController.restartConnector(settings: settings) },
            pushConfiguration: { try await CloudflareService.publishTunnel(settings: settings.cloudflareSettings, routes: routes, sites: sites, projects: projects) })
    }, probeRoute: @escaping (String) async -> RouteHealth = { await RouteHealthService().check(hostname: $0) },
       refreshDNS: @escaping () async throws -> Void = { try await RouteHealthService.refreshMacDNS() }) {
        self.applyTunnel = applyTunnel
        self.probeRoute = probeRoute
        self.refreshDNS = refreshDNS
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

    public func applyCaddy(settings: AppSettings, sites: [Site]) {
        queuedCaddy = (settings, sites)
        guard caddyTask == nil else { return }
        caddyTask = Task {
            while let (settings, sites) = queuedCaddy {
                queuedCaddy = nil
                caddyApplyState = .applying
                do {
                    let message = try await ConfigurationService.shared.applyCaddy(settings: settings, sites: sites, running: frankenphpRunning)
                    frankenphpError = nil
                    appliedCaddyInput = CaddyInput(settings: settings, sites: sites)
                    caddyApplyState = .applied(message)
                } catch {
                    frankenphpError = error.localizedDescription
                    caddyApplyState = .failed(error.localizedDescription)
                }
            }
            caddyTask = nil
        }
    }

    public func startFrankenPHP(settings: AppSettings, sites: [Site]) {
        guard !isServiceBusy("FrankenPHP") else { return }
        beginOperation("FrankenPHP")
        caddyApplyState = .applying
        Task {
            defer { endOperation("FrankenPHP") }
            // A site toggle may be applying right now: start after it instead of dropping the request.
            while let pending = caddyTask { await pending.value }
            do {
                _ = try await ConfigurationService.shared.applyCaddy(settings: settings, sites: sites, running: frankenphpRunning)
                if !frankenphpRunning {
                    try await Self.brew(.start, service: "frankenphp")
                    guard await Self.waitForCaddy() else { throw ConfigurationFailure("FrankenPHP did not become ready. Check its log.") }
                }
                frankenphpRunning = true
                frankenphpError = nil
                appliedCaddyInput = CaddyInput(settings: settings, sites: sites)
                caddyApplyState = .applied("Applied to Caddy")
                restoreSystemRulesIfNeeded()
            } catch {
                frankenphpError = error.localizedDescription
                caddyApplyState = .failed(error.localizedDescription)
            }
        }
    }

    public func stopFrankenPHP() { stopBrew("frankenphp", displayName: "FrankenPHP") }
    public func stopMariaDB() { stopBrew("mariadb", displayName: "MariaDB") }
    private func stopBrew(_ name: String, displayName: String) {
        guard !isServiceBusy(displayName) else { return }
        beginOperation(displayName)
        Task {
            defer { endOperation(displayName) }
            do {
                try await Self.brew(.stop, service: name)
                let stillRunning = await BlockingWork.run { () -> Bool in
                    if name == "frankenphp" { return LocalRedirectProbe.isCaddyAdminReachable() }
                    return Self.processExists("mariadbd")
                }
                if name == "frankenphp" {
                    frankenphpRunning = stillRunning
                    frankenphpError = stillRunning ? "An externally managed FrankenPHP/Caddy instance is still running." : nil
                    if !stillRunning { caddyApplyState = .unverified }
                } else {
                    mariadbRunning = stillRunning
                    mariadbError = stillRunning ? "An externally managed MariaDB instance is still running." : nil
                }
            } catch {
                if name == "frankenphp" { frankenphpError = error.localizedDescription }
                else { mariadbError = error.localizedDescription }
            }
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
                try await Self.brew(.start, service: "mariadb")
                var ready = false
                for _ in 0..<20 {
                    if await BlockingWork.run({ Self.processExists("mariadbd") }) { ready = true; break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard ready else { throw ConfigurationFailure("MariaDB did not start. Check its log.") }
                mariadbRunning = true
                mariadbError = nil
            } catch { mariadbError = error.localizedDescription }
        }
    }

    public func applyTunnels(settings: AppSettings, routes: [TunnelRoute], sites: [Site], projects: [AppProject], push: Bool? = nil, start: Bool = false) {
        guard !isServiceBusy("Cloudflared") || tunnelTask != nil else { return }
        let input = TunnelInput(settings: settings, routes: routes, sites: sites, projects: projects)
        desiredTunnelInput = input
        healthGeneration = UUID()
        dnsRefreshError = nil
        assign(\.routeHealth, [:])
        queuedTunnel = TunnelRequest(settings: settings, routes: routes, sites: sites, projects: projects,
                                     push: push ?? settings.cloudflareSettings.hasAPIConfiguration, start: start)
        guard tunnelTask == nil else { return }
        tunnelApplyState = .applying
        beginOperation("Cloudflared")
        tunnelTask = Task {
            defer { tunnelTask = nil; endOperation("Cloudflared") }
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
        }
    }

    public func stopCloudflared() {
        guard !isServiceBusy("Cloudflared") else { return }
        beginOperation("Cloudflared")
        Task {
            defer { endOperation("Cloudflared") }
            let (result, running) = await BlockingWork.run {
                let result = LaunchAgentService.stop(label: Self.cloudflaredLaunchAgentLabel)
                return (result, LaunchAgentService.isRunning(label: Self.cloudflaredLaunchAgentLabel))
            }
            cloudflaredRunning = running
            cloudflaredError = result.status == 0 || !running ? nil : "Could not stop connector: \(result.output)"
            if !running { tunnelApplyState = .unverified }
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

    public nonisolated static func removeLegacyCloudflaredLaunchAgents() {
        for label in legacyCloudflaredLaunchAgentLabels where label != cloudflaredLaunchAgentLabel {
            if LaunchAgentService.isInstalled(label: label) { _ = LaunchAgentService.stop(label: label) }
        }
    }

    private struct StatusSnapshot: Sendable {
        var frankenphp: Bool
        var mariadb: Bool
        var cloudflared: Bool
        var projects: [(id: String, state: ProjectRuntimeState)]
    }

    /// One snapshot answers every project: a handful of process launches per refresh,
    /// however many projects exist.
    public func refreshStatusSnapshot(settings: AppSettings, projects: [AppProject]) {
        guard AppSettings.reviewDirectory == nil, refreshTask == nil else { return }
        let generation = stateGeneration
        refreshTask = Task {
            let snapshot = await BlockingWork.run {
                let plans = projects.map { ProjectLaunchPlanner.plan(for: $0) }
                let processes = ProcessSnapshot.capture(ports: plans.map(\.port))
                let lifecycle = ProjectLifecycleService(snapshot: processes)
                return StatusSnapshot(
                    frankenphp: LocalRedirectProbe.isCaddyAdminReachable(),
                    mariadb: Self.processExists("mariadbd"),
                    cloudflared: processes.runningJobs[Self.cloudflaredLaunchAgentLabel] != nil,
                    projects: plans.map { (id: $0.projectID, state: lifecycle.state($0)) }
                )
            }
            refreshTask = nil
            guard generation == stateGeneration else { return }
            if !isServiceBusy("FrankenPHP") { assign(\.frankenphpRunning, snapshot.frankenphp) }
            if !isServiceBusy("MariaDB") { assign(\.mariadbRunning, snapshot.mariadb) }
            if !isServiceBusy("Cloudflared") { assign(\.cloudflaredRunning, snapshot.cloudflared) }
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
    public func startProject(_ project: AppProject) { operateProject(project, start: true) }
    public func stopProject(_ project: AppProject) { operateProject(project, start: false) }
    private func operateProject(_ project: AppProject, start: Bool) {
        runProjectOperation(project.id, start ? .starting : .stopping) {
            let plan = ProjectLaunchPlanner.plan(for: project)
            return start ? ProjectLifecycleService().start(plan) : ProjectLifecycleService().stop(plan)
        }
    }

    /// Applies an edit to a running project: the old definition (port, command, directory)
    /// is stopped before the new one starts, so nothing keeps serving the old port.
    public func restartProject(from previous: AppProject, to updated: AppProject) {
        runProjectOperation(updated.id, .starting) {
            let service = ProjectLifecycleService()
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
    }

    /// Stops a project before its record is deleted. Returns an error, and leaves the project
    /// in place, if it is still running or its launch agent (which starts at login) remains.
    public func stopProjectForDeletion(_ project: AppProject) async -> String? {
        guard projectOperations[project.id] == nil else { return "\(project.name) is busy. Try again when it finishes." }
        projectOperations[project.id] = .stopping
        projectErrors[project.id] = nil
        stateGeneration += 1
        let (outcome, agentRemains) = await BlockingWork.run(qos: .userInitiated) { () -> (ProjectRuntimeState, Bool) in
            let plan = ProjectLaunchPlanner.plan(for: project)
            let service = ProjectLifecycleService()
            let outcome = service.stop(plan)
            return (outcome, service.hasInstalledAgent(plan))
        }
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

    /// Publication and manual retries share the same per-route check. Ignore results for
    /// routes edited/deleted while a request was in flight.
    public func checkRoute(_ route: TunnelRoute, retry: Bool = false) {
        let generation = healthGeneration
        let checkID = UUID()
        healthChecks[route.id] = checkID
        routeHealth[route.id] = .checking
        Task {
            var result = await probeRoute(route.publicHostname)
            if retry, result == .dnsPending || result == .httpError(404) || result == .httpError(502) {
                try? await Task.sleep(for: .seconds(2))
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
    private nonisolated static func waitForCaddy() async -> Bool {
        for _ in 0..<20 {
            if await BlockingWork.run({ LocalRedirectProbe.isCaddyAdminReachable() }) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// Call once at launch and after wake, not on every window appearance: a broken redirect
    /// may need an administrator prompt to repair.
    public func reconcileSystemNetworkState() {
        guard AppSettings.reviewDirectory == nil else { return }
        Task {
            let running = await BlockingWork.run { LocalRedirectProbe.isCaddyAdminReachable() }
            if !isServiceBusy("FrankenPHP") { assign(\.frankenphpRunning, running) }
            restoreSystemRulesIfNeeded()
        }
    }
    public func handleSystemWake() { reconcileSystemNetworkState() }

    /// Flush DNS cache and restore PF port redirect rules if FrankenPHP is running.
    /// Only one check/repair runs at a time, so wake and launch cannot stack prompts.
    private func restoreSystemRulesIfNeeded() {
        Self.flushDNSCache()

        guard frankenphpRunning, !isRestoringNetwork else { return }
        isRestoringNetwork = true
        Task {
            defer { isRestoringNetwork = false }
            await BlockingWork.run(qos: .userInitiated) {
                switch PFRestorePlanner.decision(
                    frankenphpRunning: true,
                    redirectWorking: LocalRedirectProbe.isRedirectReachingCaddy()
                ) {
                case .reloadPF:
                    _ = Self.reloadPFRules()
                case .skipFrankenPHPStopped, .skipRedirectAlreadyWorking:
                    break
                }
            }
        }
    }

    /// Reload PF rules to restore port 80/443 → 8080/8443 redirects.
    /// With the privileged helper installed this never prompts; otherwise it asks for an
    /// administrator password and gives the user time to type it.
    private nonisolated static func reloadPFRules() -> Bool {
        if PFHelperManager.status == .enabled {
            guard PFHelperManager.kickstart() else { return false }
            // launchd throttles the helper (ThrottleInterval 5) and TLS may still be warming up.
            let deadline = Date().addingTimeInterval(8)
            repeat {
                Thread.sleep(forTimeInterval: 0.5)
                if LocalRedirectProbe.isRedirectReachingCaddy() { return true }
            } while Date() < deadline
            return false
        }

        let result = SystemProcess.capture(
            "/usr/bin/osascript",
            arguments: [
                "-e",
                "do shell script \"/sbin/pfctl -ef /etc/pf.conf 2>/dev/null\" with administrator privileges"
            ],
            timeout: 600
        )

        return result.status == 0
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
