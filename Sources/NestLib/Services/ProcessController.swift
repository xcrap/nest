import Foundation
import Combine

/// Manages FrankenPHP and MariaDB processes.
@MainActor
public final class ProcessController: ObservableObject {
    @Published public var frankenphpRunning = false
    @Published public var mariadbRunning = false
    @Published public var frankenphpError: String?
    @Published public var mariadbError: String?

    private var frankenphpProcess: Process?
    private var mariadbProcess: Process?

    private let pidDirectory: String

    /// PID of an externally-started FrankenPHP process (not managed by us).
    private var externalFrankenPHPPid: Int32?
    /// PID of an externally-started MariaDB process.
    private var externalMariaDBPid: Int32?

    public init() {
        let appSupport = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first ?? ("~/Library/Application Support" as NSString).expandingTildeInPath
        self.pidDirectory = (appSupport as NSString).appendingPathComponent("Nest/run")
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
        let configData: Data
        do {
            let caddyfile = try String(contentsOfFile: caddyfilePath, encoding: .utf8)
            let payload: [String: Any] = ["load": caddyfile]
            // Use the admin API reload endpoint
            configData = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            frankenphpError = "Failed to read Caddyfile for reload: \(error.localizedDescription)"
            return
        }

        var request = URLRequest(url: URL(string: "http://localhost:2019/load")!)
        request.httpMethod = "POST"
        request.setValue("text/caddyfile", forHTTPHeaderField: "Content-Type")

        do {
            let caddyfile = try String(contentsOfFile: caddyfilePath, encoding: .utf8)
            request.httpBody = caddyfile.data(using: .utf8)
        } catch {
            frankenphpError = "Failed to read Caddyfile: \(error.localizedDescription)"
            return
        }

        let _ = configData // suppress unused warning

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            Task { @MainActor in
                if let error {
                    self?.frankenphpError = "Reload failed: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    self?.frankenphpError = "Reload returned status \(http.statusCode)"
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
}
