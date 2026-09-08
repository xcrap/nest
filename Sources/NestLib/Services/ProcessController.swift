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
    @Published public private(set) var routeHealth: [String: String] = [:]
    private var refreshTask: Task<Void, Never>?
    private var caddyTask: Task<Void, Never>?
    private struct TunnelInput: Equatable {
        var settings: AppSettings
        var routes: [TunnelRoute]
        var sites: [Site]
        var projects: [AppProject]
    }
    private var desiredTunnelInput: TunnelInput?
    public func markTunnelsPending(settings: AppSettings, routes: [TunnelRoute], sites: [Site], projects: [AppProject]) {
        let input = TunnelInput(settings: settings, routes: routes, sites: sites, projects: projects)
        guard desiredTunnelInput != input else { return }
        desiredTunnelInput = input
        routeHealth = [:]
        if !isServiceBusy("Cloudflared") { tunnelApplyState = .pending }
    }
    private var queuedCaddy: (AppSettings, [Site])?

    public nonisolated static var cloudflaredLaunchAgentLabel: String {
        "app.nest.\(AppSettings.storageRootName.replacingOccurrences(of: ".", with: "-")).cloudflared"
    }
    public nonisolated static let legacyCloudflaredLaunchAgentLabels = ["app.nest.cloudflared"]
    public init() {}

    public func isServiceBusy(_ service: String) -> Bool { serviceOperations.contains(service) }

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
        guard !isServiceBusy("FrankenPHP"), caddyTask == nil else { return }
        serviceOperations.insert("FrankenPHP")
        caddyApplyState = .applying
        Task {
            defer { serviceOperations.remove("FrankenPHP") }
            do {
                _ = try await ConfigurationService.shared.applyCaddy(settings: settings, sites: sites, running: frankenphpRunning)
                if !frankenphpRunning {
                    try await Self.brew(.start, service: "frankenphp")
                    guard await Self.waitForCaddy() else { throw ConfigurationFailure("FrankenPHP did not become ready. Check its log.") }
                }
                frankenphpRunning = true
                frankenphpError = nil
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
        serviceOperations.insert(displayName)
        Task {
            defer { serviceOperations.remove(displayName) }
            do {
                try await Self.brew(.stop, service: name)
                let stillRunning = await Task.detached { () -> Bool in
                    if name == "frankenphp" { return Self.caddyReady() }
                    return Self.processExists("mariadbd")
                }.value
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
        serviceOperations.insert("MariaDB")
        Task {
            defer { serviceOperations.remove("MariaDB") }
            do {
                guard FileManager.default.isExecutableFile(atPath: serverBinary) else { throw ConfigurationFailure("MariaDB binary is not executable at \(serverBinary).") }
                try await Self.brew(.start, service: "mariadb")
                let ready = await Task.detached {
                    for _ in 0..<20 {
                        if Self.processExists("mariadbd") { return true }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    return false
                }.value
                guard ready else { throw ConfigurationFailure("MariaDB did not start. Check its log.") }
                mariadbRunning = true
                mariadbError = nil
            } catch { mariadbError = error.localizedDescription }
        }
    }

    public func applyTunnels(settings: AppSettings, routes: [TunnelRoute], sites: [Site], projects: [AppProject], push: Bool = false, start: Bool = false) {
        guard !tunnelApplyState.isBusy, !isServiceBusy("Cloudflared") else { return }
        let input = TunnelInput(settings: settings, routes: routes, sites: sites, projects: projects)
        desiredTunnelInput = input
        tunnelApplyState = .applying
        serviceOperations.insert("Cloudflared")
        let shouldRun = start || cloudflaredRunning
        Task {
            defer { serviceOperations.remove("Cloudflared") }
            do {
                let message = try await ConfigurationService.shared.applyTunnel(settings: settings, routes: routes, sites: sites, projects: projects,
                    running: shouldRun, push: push, restart: { try await Self.restartConnector(settings: settings) })
                cloudflaredRunning = shouldRun
                cloudflaredError = nil
                tunnelApplyState = desiredTunnelInput == input ? .applied(message) : .pending
                routeHealth = [:]
            } catch {
                cloudflaredError = error.localizedDescription
                tunnelApplyState = .failed(error.localizedDescription)
            }
        }
    }

    public func stopCloudflared() {
        guard !isServiceBusy("Cloudflared") else { return }
        serviceOperations.insert("Cloudflared")
        Task {
            defer { serviceOperations.remove("Cloudflared") }
            let result = await Task.detached { LaunchAgentService.stop(label: Self.cloudflaredLaunchAgentLabel) }.value
            let running = await Task.detached { LaunchAgentService.isRunning(label: Self.cloudflaredLaunchAgentLabel) }.value
            cloudflaredRunning = running
            cloudflaredError = result.status == 0 || !running ? nil : "Could not stop connector: \(result.output)"
            if !running { tunnelApplyState = .unverified }
        }
    }

    public nonisolated static func restartConnector(settings: AppSettings) async throws {
        let result = await Task.detached {
            LaunchAgentService.start(connectorDefinition(settings: settings))
        }.value
        guard result.status == 0 else { throw ConfigurationFailure("Connector restart failed: \(result.output)") }
        for _ in 0..<20 {
            let running = await Task.detached { LaunchAgentService.isRunning(label: cloudflaredLaunchAgentLabel) }.value
            if running {
                // A process that immediately exits is not a successful restart.
                try await Task.sleep(for: .seconds(1))
                if await Task.detached(operation: { LaunchAgentService.isRunning(label: cloudflaredLaunchAgentLabel) }).value { return }
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

    public func refreshStatusSnapshot(settings: AppSettings, projects: [AppProject]) {
        guard AppSettings.reviewDirectory == nil, refreshTask == nil else { return }
        let plans = projects.map { ProjectLaunchPlanner.plan(for: $0) }
        refreshTask = Task {
            let snapshot = await Task.detached(priority: .utility) {
                let php = Self.caddyReady()
                let db = Self.processExists("mariadbd")
                let tunnel = LaunchAgentService.isRunning(label: Self.cloudflaredLaunchAgentLabel)
                let states = plans.map { ($0.projectID, ProjectLifecycleService().state($0)) }
                return (php, db, tunnel, states)
            }.value
            if !isServiceBusy("FrankenPHP") { frankenphpRunning = snapshot.0 }
            if !isServiceBusy("MariaDB") { mariadbRunning = snapshot.1 }
            if !isServiceBusy("Cloudflared") { cloudflaredRunning = snapshot.2 }
            for (id, state) in snapshot.3 where projectOperations[id] == nil {
                projectStatuses[id] = state.running
                if let error = state.error { projectErrors[id] = error }
                else if projectErrors[id]?.hasPrefix("Port ") == true { projectErrors[id] = nil }
            }
            refreshTask = nil
        }
    }
    public func refreshProjectStatuses(_ projects: [AppProject]) {
        refreshStatusSnapshot(settings: AppSettings(), projects: projects)
    }
    public func startProject(_ project: AppProject) { operateProject(project, start: true) }
    public func stopProject(_ project: AppProject) { operateProject(project, start: false) }
    private func operateProject(_ project: AppProject, start: Bool) {
        guard projectOperations[project.id] == nil else { return }
        projectOperations[project.id] = start ? .starting : .stopping
        projectErrors[project.id] = nil
        let plan = ProjectLaunchPlanner.plan(for: project)
        Task {
            let outcome = await Task.detached { start ? ProjectLifecycleService().start(plan) : ProjectLifecycleService().stop(plan) }.value
            projectOperations[project.id] = nil
            projectStatuses[project.id] = outcome.running
            projectErrors[project.id] = outcome.error
        }
    }
    public func isProjectRunning(_ project: AppProject) -> Bool { projectStatuses[project.id] ?? false }
    public func isProjectBusy(_ project: AppProject) -> Bool { projectOperations[project.id] != nil }
    public func projectOperation(for id: String) -> ProjectOperation? { projectOperations[id] }
    public func projectError(for id: String) -> String? { projectErrors[id] }
    public func stopAll() { stopFrankenPHP(); stopMariaDB(); stopCloudflared() }

    /// HTTP checks are explicit and per-route; process presence never claims public reachability.
    public func checkRoute(_ route: TunnelRoute) {
        routeHealth[route.id] = "Checking…"
        Task {
            do {
                guard let url = URL(string: "https://\(route.publicHostname)") else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 10
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                routeHealth[route.id] = (200..<400).contains(status) ? "Reachable • HTTP \(status)" : "HTTP \(status) • inspect origin / tunnel"
            } catch { routeHealth[route.id] = "Unreachable: \(error.localizedDescription)" }
        }
    }

    private nonisolated static func brew(_ action: BrewServiceAction, service: String) async throws {
        let result = await SystemProcess.captureAsync(BrewServiceController.brewPath, arguments: ["services", action.rawValue, service], timeout: 120)
        guard result.status == 0 else { throw ConfigurationFailure(result.output) }
    }
    private nonisolated static func processExists(_ name: String) -> Bool {
        SystemProcess.capture("/usr/bin/pgrep", arguments: ["-x", name], timeout: 3).status == 0
    }
    private nonisolated static func caddyReady() -> Bool {
        let result = SystemProcess.capture("/usr/bin/curl", arguments: ["--silent", "--fail", "--max-time", "2", "--output", "/dev/null", "http://localhost:2019/config/"], timeout: 3)
        return result.status == 0
    }
    private nonisolated static func waitForCaddy() async -> Bool {
        for _ in 0..<20 {
            if await Task.detached(operation: { caddyReady() }).value { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
    public func reconcileSystemNetworkState() {
        guard AppSettings.reviewDirectory == nil else { return }
        Task {
            frankenphpRunning = await Task.detached { Self.caddyReady() }.value
            restoreSystemRulesIfNeeded()
        }
    }
    public func handleSystemWake() { reconcileSystemNetworkState() }
    /// Flush DNS cache and restore PF port redirect rules if FrankenPHP is running.
    /// Called on both app startup and system wake.
    private func restoreSystemRulesIfNeeded() {
        flushDNSCache()

        let shouldCheckRedirects = frankenphpRunning
        guard shouldCheckRedirects else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self, shouldCheckRedirects] in
            guard let self else { return }
            switch PFRestorePlanner.decision(
                frankenphpRunning: shouldCheckRedirects,
                redirectWorking: self.isPortRedirectWorking()
            ) {
            case .reloadPF:
                guard self.reloadPFRules() else { return }
                _ = self.isPortRedirectWorking()
            case .skipFrankenPHPStopped, .skipRedirectAlreadyWorking:
                return
            }
        }
    }

    /// Test whether PF redirects port 80 to 8080 (reaches Caddy).
    private nonisolated func isPortRedirectWorking() -> Bool {
        isHTTPEndpointReachable("http://localhost:80") &&
            isHTTPEndpointReachable("https://localhost:443", insecureTLS: true)
    }

    /// Reload PF rules to restore port 80/443 → 8080/8443 redirects.
    /// Prefers the privileged helper (no prompt); falls back to osascript if not available.
    private nonisolated func reloadPFRules() -> Bool {
        if PFHelperManager.kickstart() {
            // launchd may take a moment to fire WatchPaths; give it time to run pfctl.
            Thread.sleep(forTimeInterval: 1.5)
            if isPortRedirectWorking() {
                return true
            }
        }

        let result = SystemProcess.capture(
            "/usr/bin/osascript",
            arguments: [
                "-e",
                "do shell script \"/sbin/pfctl -ef /etc/pf.conf 2>/dev/null\" with administrator privileges"
            ]
        )

        return result.status == 0
    }

    /// Flush macOS DNS cache so .test domains resolve immediately.
    private nonisolated func flushDNSCache() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        process.arguments = ["-flushcache"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private nonisolated func isHTTPEndpointReachable(_ url: String, insecureTLS: Bool = false) -> Bool {
        var arguments = [
            "-I",
            "--silent",
            "--output", "/dev/null",
            "--write-out", "%{http_code}",
            "--max-time", "2"
        ]

        if insecureTLS {
            arguments.append("-k")
        }

        arguments.append(url)

        let result = SystemProcess.capture("/usr/bin/curl", arguments: arguments)
        guard result.status == 0 else { return false }

        let statusCode = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !statusCode.isEmpty && statusCode != "000"
    }

}
