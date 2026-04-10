import Foundation
import Combine
import Darwin

/// Manages FrankenPHP and MariaDB processes.
@MainActor
public final class ProcessController: ObservableObject {
    @Published public var frankenphpRunning = false
    @Published public var mariadbRunning = false
    @Published public var cloudflaredRunning = false
    @Published public var frankenphpError: String?
    @Published public var mariadbError: String?
    @Published public var cloudflaredError: String?
    @Published public private(set) var projectStatuses: [String: Bool] = [:]
    @Published public private(set) var projectErrors: [String: String] = [:]

    private var frankenphpProcess: Process?
    private var mariadbProcess: Process?
    private var projectStatusRefreshTask: Task<Void, Never>?

    private let pidDirectory: String

    private struct ProjectPort: Sendable {
        let id: String
        let port: Int
    }

    /// PID of an externally-started FrankenPHP process (not managed by us).
    private var externalFrankenPHPPid: Int32?
    /// PID of an externally-started MariaDB process.
    private var externalMariaDBPid: Int32?
    /// Label used for the Nest-managed Cloudflared launch agent.
    public static var cloudflaredLaunchAgentLabel: String {
        "\(launchAgentNamespace).cloudflared"
    }

    private static var launchAgentNamespace: String {
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
        // Check FrankenPHP via PID file, then verify the process is alive
        if let pid = readPID(name: "frankenphp"), isProcessAlive(pid) {
            externalFrankenPHPPid = pid
            frankenphpRunning = true
        } else {
            // Fallback: check if Caddy admin API is responding (FrankenPHP started externally)
            checkCaddyAdmin()
        }

        // Check MariaDB via pgrep
        if let pid = findProcessPID(name: "mariadbd") {
            externalMariaDBPid = pid
            mariadbRunning = true
        }

        cloudflaredRunning = isCloudflaredProcessRunning()
    }

    private func checkCaddyAdmin() {
        guard let url = URL(string: "http://localhost:2019/config/") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let semaphore = DispatchSemaphore(value: 0)
        var alive = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                alive = true
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.5)
        if alive {
            // Find the actual PID
            if let pid = findProcessPID(name: "frankenphp") {
                externalFrankenPHPPid = pid
            }
            frankenphpRunning = true
        }
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
        runBrewServices("start", "frankenphp") { [weak self] success, error in
            Task { @MainActor in
                if success {
                    self?.frankenphpRunning = true
                } else {
                    self?.frankenphpError = error ?? "Failed to start FrankenPHP"
                }
            }
        }
    }

    public func stopFrankenPHP() {
        runBrewServices("stop", "frankenphp") { [weak self] _, _ in
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
        runBrewServices("start", "mariadb") { [weak self] success, error in
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
        runBrewServices("stop", "mariadb") { [weak self] _, _ in
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
        guard !cloudflaredRunning else { return }
        cloudflaredError = nil

        guard !settings.runtimePaths.cloudflaredBinary.isEmpty else {
            cloudflaredError = "cloudflared binary path is not set."
            return
        }

        guard settings.cloudflareSettings.hasLocalConfiguration else {
            cloudflaredError = "Cloudflare tunnel configuration is incomplete."
            return
        }

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
        _ = SystemProcess.capture("/usr/bin/pkill", arguments: ["-f", "cloudflared.*tunnel.*run"])
        cloudflaredRunning = false
    }

    public func refreshStatusSnapshot(settings: AppSettings, projects: [AppProject]) {
        detectRunningProcesses()
        cloudflaredRunning = isCloudflaredProcessRunning()
        refreshProjectStatuses(projects)
    }

    // MARK: - App Projects

    public func startProject(_ project: AppProject) {
        projectErrors[project.id] = nil

        if Self.isPortInUse(project.port) {
            projectStatuses[project.id] = true
            return
        }

        let resolvedCommand = resolveCommand(for: project)
        let result = LaunchAgentService.start(
            LaunchAgentDefinition(
                label: project.launchAgentLabel,
                programArguments: ["/bin/zsh", "-lc", resolvedCommand],
                workingDirectory: project.directory,
                environment: [
                    "PATH": launchPath(),
                    "PORT": "\(project.port)",
                    "HOST": "0.0.0.0"
                ],
                standardOutPath: project.logPath,
                standardErrorPath: project.logPath
            )
        )

        if result.status == 0 {
            projectStatuses[project.id] = true
        } else {
            projectErrors[project.id] = result.output.isEmpty ? "Failed to start \(project.name)" : result.output
        }
    }

    public func stopProject(_ project: AppProject) {
        _ = LaunchAgentService.stop(label: project.launchAgentLabel)

        for pid in Self.pids(onPort: project.port) {
            killProcess(pid)
        }

        projectStatuses[project.id] = false
    }

    public func isProjectRunning(_ project: AppProject) -> Bool {
        projectStatuses[project.id] ?? false
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
                updated[project.id] = Self.isPortInUse(project.port)
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
        detectRunningProcesses()
        flushDNSCache()

        let shouldCheckPF = frankenphpRunning
        guard shouldCheckPF else { return }

        // Check if PF port redirect survived sleep; reload if broken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.isPortRedirectWorking() else { return }
            self.reloadPFRules()
        }
    }

    /// Test whether PF redirects port 80 to 8080 (reaches Caddy).
    private nonisolated func isPortRedirectWorking() -> Bool {
        guard let url = URL(string: "http://localhost:80") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let semaphore = DispatchSemaphore(value: 0)
        var working = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if response is HTTPURLResponse { working = true }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        return working
    }

    /// Reload PF rules to restore port 80/443 → 8080/8443 redirects.
    private nonisolated func reloadPFRules() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"/sbin/pfctl -ef /etc/pf.conf 2>/dev/null\" with administrator privileges"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
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

    private func runBrewServices(_ action: String, _ service: String, completion: @escaping (Bool, String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        process.arguments = ["services", action, service]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            completion(proc.terminationStatus == 0, proc.terminationStatus == 0 ? nil : output)
        }

        do {
            try process.run()
        } catch {
            completion(false, error.localizedDescription)
        }
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
        SystemProcess.capture("/usr/bin/pgrep", arguments: ["-f", "cloudflared.*tunnel.*run"]).status == 0
    }

    private nonisolated static func isPortInUse(_ port: Int) -> Bool {
        !pids(onPort: port).isEmpty
    }

    private func launchPath() -> String {
        let homeDirectory = NSHomeDirectory()
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = [
            currentPath,
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.local/bin",
            AppSettings.nestBinDirectory,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        var seen: Set<String> = []
        var components: [String] = []

        for candidate in candidates {
            for part in candidate.split(separator: ":").map(String.init) where !part.isEmpty {
                if seen.insert(part).inserted {
                    components.append(part)
                }
            }
        }

        return components.joined(separator: ":")
    }

    private nonisolated static func pids(onPort port: Int) -> [Int32] {
        let result = SystemProcess.capture("/usr/sbin/lsof", arguments: ["-ti", ":\(port)"])
        guard result.status == 0 else { return [] }
        return result.output
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func killProcess(_ pid: Int32) {
        guard pid > 0 else { return }
        _ = Darwin.kill(pid, SIGTERM)
        usleep(500_000)
        _ = Darwin.kill(pid, SIGKILL)
    }

    private func resolveCommand(for project: AppProject) -> String {
        if !project.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return project.command
        }

        let packagePath = (project.directory as NSString).appendingPathComponent("package.json")
        guard
            let data = FileManager.default.contents(atPath: packagePath),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "bun run start"
        }

        let dependencies = (json["dependencies"] as? [String: Any] ?? [:]).merging(
            json["devDependencies"] as? [String: Any] ?? [:]
        ) { current, _ in current }
        let scripts = json["scripts"] as? [String: Any] ?? [:]

        if dependencies["next"] != nil {
            return "bun x next start -p \(project.port)"
        }
        if dependencies["vite"] != nil {
            return "bun x vite --host --port \(project.port)"
        }
        if scripts["start"] != nil {
            return "bun run start"
        }
        if scripts["dev"] != nil {
            return "bun run dev"
        }

        return "bun run start"
    }
}
