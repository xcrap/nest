import Foundation
import Combine
import Darwin

/// Manages FrankenPHP and MariaDB processes.
@MainActor
public final class ProcessController: ObservableObject {
    public enum ProjectOperation: Sendable {
        case starting
        case stopping

        var label: String {
            switch self {
            case .starting:
                "Starting"
            case .stopping:
                "Stopping"
            }
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

    private var frankenphpProcess: Process?
    private var mariadbProcess: Process?
    private var projectStatusRefreshTask: Task<Void, Never>?

    private let pidDirectory: String

    private struct ProjectPort: Sendable {
        let id: String
        let port: Int
    }

    private struct ProjectLaunchOutcome: Sendable {
        let running: Bool
        let error: String?
    }

    /// PID of an externally-started FrankenPHP process (not managed by us).
    private var externalFrankenPHPPid: Int32?
    /// PID of an externally-started MariaDB process.
    private var externalMariaDBPid: Int32?
    /// Label used for the Nest-managed Cloudflared launch agent.
    public nonisolated static var cloudflaredLaunchAgentLabel: String {
        "\(launchAgentNamespace).cloudflared"
    }

    /// Launch-agent labels used before tunnel processes were namespaced per app bundle.
    public nonisolated static let legacyCloudflaredLaunchAgentLabels = ["app.nest.cloudflared"]

    private nonisolated static var launchAgentNamespace: String {
        "app.nest.\(AppSettings.storageRootName.replacingOccurrences(of: ".", with: "-"))"
    }

    public init() {
        AppSettings.prepareStorage()
        self.pidDirectory = AppSettings.nestRunDirectory
        try? FileManager.default.createDirectory(atPath: pidDirectory, withIntermediateDirectories: true)
        detectRunningProcesses()
    }

    /// Detect already-running FrankenPHP and MariaDB at startup.
    private func detectRunningProcesses() {
        var resolvedFrankenPHPPid: Int32?
        var resolvedMariaDBPid: Int32?
        var resolvedFrankenPHPRunning = false
        var resolvedMariaDBRunning = false

        // Check FrankenPHP via PID file, then verify the process is alive
        if let pid = readPID(name: "frankenphp"), isProcessAlive(pid) {
            resolvedFrankenPHPPid = pid
            resolvedFrankenPHPRunning = true
        } else if isCaddyAdminReachable() {
            // FrankenPHP may have been started outside Nest, so the PID file can be missing.
            resolvedFrankenPHPPid = findProcessPID(name: "frankenphp")
            resolvedFrankenPHPRunning = true
        }

        // Check MariaDB via pgrep
        if let pid = findProcessPID(name: "mariadbd") {
            resolvedMariaDBPid = pid
            resolvedMariaDBRunning = true
        }

        externalFrankenPHPPid = resolvedFrankenPHPPid
        externalMariaDBPid = resolvedMariaDBPid
        frankenphpRunning = resolvedFrankenPHPRunning
        mariadbRunning = resolvedMariaDBRunning
        cloudflaredRunning = isCloudflaredProcessRunning()
    }

    private func readPID(name: String) -> Int32? {
        let path = (pidDirectory as NSString).appendingPathComponent("\(name).pid")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(content) else { return nil }
        return pid
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private func findProcessPID(name: String) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(output.components(separatedBy: "\n").first ?? "") else { return nil }
        return pid
    }

    // MARK: - FrankenPHP

    public func startFrankenPHP(binary: String, caddyfilePath: String) {
        guard !frankenphpRunning else { return }
        frankenphpError = nil
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            frankenphpError = "FrankenPHP binary is not executable at \(binary)."
            return
        }
        guard FileManager.default.fileExists(atPath: caddyfilePath) else {
            frankenphpError = "Caddyfile was not written at \(caddyfilePath)."
            return
        }
        BrewServiceController.run(.start, service: "frankenphp") { [weak self] success, error in
            Task { @MainActor in
                if success {
                    self?.frankenphpRunning = true
                    self?.restoreSystemRulesIfNeeded()
                } else {
                    self?.frankenphpError = error ?? "Failed to start FrankenPHP"
                }
            }
        }
    }

    public func stopFrankenPHP() {
        BrewServiceController.run(.stop, service: "frankenphp") { [weak self] _, _ in
            // Also kill directly in case it wasn't started via brew
            self?.killAll("frankenphp")
            Task { @MainActor in
                self?.frankenphpRunning = false
                self?.frankenphpProcess = nil
                self?.externalFrankenPHPPid = nil
            }
        }
    }

    /// Reload FrankenPHP config via the Caddy admin API.
    public func reloadFrankenPHP(caddyfilePath: String) {
        guard let caddyfile = try? String(contentsOfFile: caddyfilePath, encoding: .utf8) else {
            frankenphpError = "Failed to read Caddyfile for reload"
            return
        }

        var request = URLRequest(url: URL(string: "http://localhost:2019/load")!)
        request.httpMethod = "POST"
        request.setValue("text/caddyfile", forHTTPHeaderField: "Content-Type")
        request.httpBody = caddyfile.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                if let error {
                    self?.frankenphpError = "Reload failed: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    self?.frankenphpError = "Reload error: \(body)"
                }
            }
        }.resume()
    }

    // MARK: - MariaDB

    public func startMariaDB(serverBinary: String) {
        guard !mariadbRunning else { return }
        mariadbError = nil
        guard FileManager.default.isExecutableFile(atPath: serverBinary) else {
            mariadbError = "MariaDB server binary is not executable at \(serverBinary)."
            return
        }
        BrewServiceController.run(.start, service: "mariadb") { [weak self] success, error in
            Task { @MainActor in
                if success {
                    self?.mariadbRunning = true
                } else {
                    self?.mariadbError = error ?? "Failed to start MariaDB"
                }
            }
        }
    }

    public func stopMariaDB() {
        BrewServiceController.run(.stop, service: "mariadb") { [weak self] _, _ in
            // Also kill directly in case it wasn't started via brew
            self?.killAll("mariadbd")
            Task { @MainActor in
                self?.mariadbRunning = false
                self?.mariadbProcess = nil
                self?.externalMariaDBPid = nil
            }
        }
    }

    // MARK: - Cleanup

    public func stopAll() {
        stopFrankenPHP()
        stopMariaDB()
    }

    // MARK: - Cloudflared

    public func startCloudflared(settings: AppSettings) {
        cloudflaredError = nil

        guard !settings.runtimePaths.cloudflaredBinary.isEmpty else {
            cloudflaredError = "cloudflared binary path is not set."
            return
        }
        guard FileManager.default.isExecutableFile(atPath: settings.runtimePaths.cloudflaredBinary) else {
            cloudflaredError = "cloudflared binary is not executable at \(settings.runtimePaths.cloudflaredBinary)."
            return
        }

        guard settings.cloudflareSettings.hasLocalConfiguration else {
            cloudflaredError = "Cloudflare tunnel configuration is incomplete."
            return
        }

        Self.removeLegacyCloudflaredLaunchAgents()

        let definition = LaunchAgentDefinition(
            label: Self.cloudflaredLaunchAgentLabel,
            programArguments: [
                settings.runtimePaths.cloudflaredBinary,
                "--config",
                settings.cloudflareSettings.configPath,
                "tunnel",
                "run",
                settings.cloudflareSettings.tunnelName
            ],
            environment: [:],
            standardOutPath: settings.runtimePaths.cloudflaredLog,
            standardErrorPath: settings.runtimePaths.cloudflaredLog
        )

        let result = LaunchAgentService.start(definition)
        if result.status == 0 {
            cloudflaredRunning = true
        } else {
            cloudflaredError = result.output.isEmpty ? "Failed to start cloudflared" : result.output
        }
    }

    public func stopCloudflared() {
        _ = LaunchAgentService.stop(label: Self.cloudflaredLaunchAgentLabel)
        Self.removeLegacyCloudflaredLaunchAgents()
        _ = SystemProcess.capture("/usr/bin/pkill", arguments: ["-f", "cloudflared.*tunnel.*run"])
        cloudflaredRunning = false
    }

    public nonisolated static func removeLegacyCloudflaredLaunchAgents() {
        for label in legacyCloudflaredLaunchAgentLabels where label != cloudflaredLaunchAgentLabel {
            guard LaunchAgentService.isInstalled(label: label) else { continue }
            _ = LaunchAgentService.stop(label: label)
        }
    }

    public func refreshStatusSnapshot(settings: AppSettings, projects: [AppProject]) {
        detectRunningProcesses()
        cloudflaredRunning = isCloudflaredProcessRunning()
        refreshProjectStatuses(projects)
    }

    public func reconcileSystemNetworkState() {
        detectRunningProcesses()
        restoreSystemRulesIfNeeded()
    }

    // MARK: - App Projects

    public func startProject(_ project: AppProject) {
        guard projectOperations[project.id] == nil else { return }
        projectErrors[project.id] = nil
        projectOperations[project.id] = .starting

        let plan = ProjectLaunchPlanner.plan(for: project, launchPath: Self.launchPath())

        Task { [plan] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.performProjectStart(plan)
            }.value

            projectOperations.removeValue(forKey: plan.projectID)
            projectStatuses[plan.projectID] = outcome.running
            projectErrors[plan.projectID] = outcome.error
        }
    }

    public func stopProject(_ project: AppProject) {
        guard projectOperations[project.id] == nil else { return }
        projectErrors[project.id] = nil
        projectOperations[project.id] = .stopping

        let plan = ProjectLaunchPlanner.plan(for: project, launchPath: Self.launchPath())

        Task { [plan] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.performProjectStop(plan)
            }.value

            projectOperations.removeValue(forKey: plan.projectID)
            projectStatuses[plan.projectID] = outcome.running
            projectErrors[plan.projectID] = outcome.error
        }
    }

    public func isProjectRunning(_ project: AppProject) -> Bool {
        projectStatuses[project.id] ?? false
    }

    public func isProjectBusy(_ project: AppProject) -> Bool {
        projectOperations[project.id] != nil
    }

    public func projectOperation(for id: String) -> ProjectOperation? {
        projectOperations[id]
    }

    public func projectError(for id: String) -> String? {
        projectErrors[id] ?? nil
    }

    public func refreshProjectStatuses(_ projects: [AppProject]) {
        let snapshot = projects.map { ProjectPort(id: $0.id, port: $0.port) }

        projectStatusRefreshTask?.cancel()
        projectStatusRefreshTask = Task.detached(priority: .utility) { [snapshot] in
            var updated: [String: Bool] = [:]
            updated.reserveCapacity(snapshot.count)

            for project in snapshot {
                guard !Task.isCancelled else { return }
            updated[project.id] = PortInspector.isPortInUse(project.port)
            }

            guard !Task.isCancelled else { return }
            let resolvedStatuses = updated

            await MainActor.run {
                self.projectStatuses = resolvedStatuses
            }
        }
    }

    // MARK: - Wake Recovery

    /// Restore services after system wake from sleep.
    /// macOS can flush PF redirect rules and DNS cache during sleep.
    public func handleSystemWake() {
        reconcileSystemNetworkState()
    }

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

    private nonisolated func isCaddyAdminReachable() -> Bool {
        isHTTPEndpointReachable("http://localhost:2019/config/")
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

    // MARK: - Private

    private nonisolated func killAll(_ name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = [name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func writePID(_ pid: Int32, name: String) {
        let path = (pidDirectory as NSString).appendingPathComponent("\(name).pid")
        try? "\(pid)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func removePID(name: String) {
        let path = (pidDirectory as NSString).appendingPathComponent("\(name).pid")
        try? FileManager.default.removeItem(atPath: path)
    }

    private func isCloudflaredProcessRunning() -> Bool {
        LaunchAgentService.isRunning(label: Self.cloudflaredLaunchAgentLabel)
    }

    private nonisolated static func performProjectStart(_ plan: ProjectLaunchPlan) -> ProjectLaunchOutcome {
        if PortInspector.isPortInUse(plan.port) {
            return ProjectLaunchOutcome(running: true, error: nil)
        }

        let result = LaunchAgentService.start(plan.definition)

        if result.status == 0 {
            if PortInspector.waitForPortState(plan.port, inUse: true, timeoutNanoseconds: 12_000_000_000) {
                return ProjectLaunchOutcome(running: true, error: nil)
            }

            let error = "Started \(plan.projectName), but nothing began listening on port \(plan.port). Check the project log."
            return ProjectLaunchOutcome(running: false, error: error)
        }

        let error = result.output.isEmpty ? "Failed to start \(plan.projectName)" : result.output
        return ProjectLaunchOutcome(running: false, error: error)
    }

    private nonisolated static func performProjectStop(_ plan: ProjectLaunchPlan) -> ProjectLaunchOutcome {
        _ = LaunchAgentService.stop(label: plan.definition.label)

        PortInspector.killProcesses(onPort: plan.port)

        if PortInspector.waitForPortState(plan.port, inUse: false, timeoutNanoseconds: 5_000_000_000) {
            return ProjectLaunchOutcome(running: false, error: nil)
        }

        let error = "Stopped \(plan.projectName), but port \(plan.port) is still in use."
        return ProjectLaunchOutcome(running: false, error: error)
    }

    private nonisolated static func launchPath() -> String {
        ProjectCommandResolver.launchPath()
    }
}
