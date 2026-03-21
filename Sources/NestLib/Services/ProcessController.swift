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

        // Check MariaDB via PID file
        if let pid = readPID(name: "mariadb"), isProcessAlive(pid) {
            externalMariaDBPid = pid
            mariadbRunning = true
        } else {
            // Fallback: check if MariaDB socket exists and is connectable
            let socketPath = (pidDirectory as NSString).appendingPathComponent("mariadb.sock")
            if FileManager.default.fileExists(atPath: socketPath) {
                // Try to find mariadb PID from the process list
                if let pid = findProcessPID(name: "mariadbd") {
                    externalMariaDBPid = pid
                    mariadbRunning = true
                }
            }
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["run", "--config", caddyfilePath, "--adapter", "caddyfile"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.frankenphpRunning = false
                self?.frankenphpProcess = nil
                if proc.terminationStatus != 0 && proc.terminationStatus != 15 {
                    self?.frankenphpError = "FrankenPHP exited with status \(proc.terminationStatus)"
                }
            }
        }

        do {
            try process.run()
            frankenphpProcess = process
            frankenphpRunning = true
            writePID(process.processIdentifier, name: "frankenphp")
        } catch {
            frankenphpError = "Failed to start FrankenPHP: \(error.localizedDescription)"
        }
    }

    public func stopFrankenPHP() {
        if let process = frankenphpProcess, process.isRunning {
            process.terminate()
        } else if let pid = externalFrankenPHPPid {
            kill(pid, SIGTERM)
            externalFrankenPHPPid = nil
        }
        frankenphpProcess = nil
        frankenphpRunning = false
        removePID(name: "frankenphp")
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

    public func startMariaDB(serverBinary: String, dataDirectory: String, configDirectory: String) {
        guard !mariadbRunning else { return }
        mariadbError = nil

        let fm = FileManager.default
        try? fm.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)

        // Check if data directory needs initialization
        let ibdata = (dataDirectory as NSString).appendingPathComponent("ibdata1")
        if !fm.fileExists(atPath: ibdata) {
            initializeMariaDB(serverBinary: serverBinary, dataDirectory: dataDirectory)
        }

        // Write MariaDB config
        let cnfPath = (configDirectory as NSString).appendingPathComponent("mariadb.cnf")
        let socketPath = (pidDirectory as NSString).appendingPathComponent("mariadb.sock")
        let logPath = ((NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? "") as NSString)
            .appendingPathComponent("Nest/logs/mariadb.log")

        let cnf = """
        [mysqld]
        datadir=\(dataDirectory)
        socket=\(socketPath)
        port=3306
        log-error=\(logPath)
        bind-address=127.0.0.1
        skip-networking=0
        """
        try? cnf.write(toFile: cnfPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary)
        process.arguments = ["--defaults-file=\(cnfPath)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.mariadbRunning = false
                self?.mariadbProcess = nil
                if proc.terminationStatus != 0 && proc.terminationStatus != 15 {
                    self?.mariadbError = "MariaDB exited with status \(proc.terminationStatus)"
                }
            }
        }

        do {
            try process.run()
            mariadbProcess = process
            mariadbRunning = true
            writePID(process.processIdentifier, name: "mariadb")
        } catch {
            mariadbError = "Failed to start MariaDB: \(error.localizedDescription)"
        }
    }

    public func stopMariaDB() {
        if let process = mariadbProcess, process.isRunning {
            process.terminate()
        } else if let pid = externalMariaDBPid {
            kill(pid, SIGTERM)
            externalMariaDBPid = nil
        }
        mariadbProcess = nil
        mariadbRunning = false
        removePID(name: "mariadb")
    }

    // MARK: - Cleanup

    public func stopAll() {
        stopFrankenPHP()
        stopMariaDB()
    }

    // MARK: - Private

    private func initializeMariaDB(serverBinary: String, dataDirectory: String) {
        // mariadb-install-db is typically in the same directory as mariadbd
        let binDir = (serverBinary as NSString).deletingLastPathComponent
        let installDB = (binDir as NSString).appendingPathComponent("mariadb-install-db")

        guard FileManager.default.isExecutableFile(atPath: installDB) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: installDB)
        process.arguments = ["--datadir=\(dataDirectory)", "--auth-root-authentication-method=normal"]
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
}
