import Foundation
import Darwin

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// Runs synchronous, blocking work (process launches, polling loops) on a dispatch queue
/// so it never occupies a thread of Swift's cooperative pool.
public enum BlockingWork {
    public static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .utility, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
        }
    }
}

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public enum SystemProcess {
    /// Spool output to a private file: a verbose child cannot fill a pipe while we wait.
    /// Only the last MiB is returned, and every invocation has a deadline.
    public static func capture(
        _ executablePath: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30,
        isCancelled: () -> Bool = { false }
    ) -> CommandResult {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("nest-command-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            return CommandResult(status: -1, output: "Cannot create command output file.")
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        do {
            let handle = try FileHandle(forUpdating: outputURL)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = handle
            process.standardInput = FileHandle.nullDevice
            if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
            if let environment { process.environment = environment }
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            var interrupted = false
            // Wake on exit immediately; the slice only bounds how quickly cancellation is noticed.
            while exited.wait(timeout: .now() + 0.1) == .timedOut {
                if isCancelled() || Date() >= deadline {
                    interrupted = true
                    process.terminate()
                    if exited.wait(timeout: .now() + 0.3) == .timedOut {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                    break
                }
            }
            process.waitUntilExit()
            let length = try handle.seekToEnd()
            try handle.seek(toOffset: length > 1_048_576 ? length - 1_048_576 : 0)
            let output = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
            return CommandResult(status: interrupted ? 124 : process.terminationStatus,
                                 output: interrupted ? "Command timed out or was cancelled.\n\(output)" : output)
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }

    public static func captureAsync(_ executablePath: String, arguments: [String] = [], timeout: TimeInterval = 30) async -> CommandResult {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler(operation: {
            await BlockingWork.run {
                capture(executablePath, arguments: arguments, timeout: timeout, isCancelled: { flag.isCancelled })
            }
        }, onCancel: { flag.cancel() })
    }
}

/// A process as it was when observed. A PID alone can be reused by an unrelated process
/// after the original exits; the start time and owner tell the two apart.
public struct ProcessIdentity: Equatable, Sendable {
    public var pid: Int32
    public var startTime: UInt64
    public var uid: UInt32

    public init(pid: Int32, startTime: UInt64, uid: UInt32) {
        self.pid = pid
        self.startTime = startTime
        self.uid = uid
    }
}

public enum ProcessTable {
    /// `SZOMB` from <sys/proc.h>: exited, waiting to be reaped.
    private static let zombieStatus: UInt32 = 5

    /// nil once the process has exited (zombies included).
    public static func identity(of pid: Int32) -> ProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != zombieStatus else { return nil }
        return ProcessIdentity(pid: pid, startTime: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, uid: info.pbi_uid)
    }

    /// Signals only the exact process recorded earlier, and only if it belongs to this user.
    @discardableResult
    public static func signal(_ recorded: ProcessIdentity, _ signal: Int32) -> Bool {
        guard recorded.uid == getuid(), identity(of: recorded.pid) == recorded else { return false }
        return Darwin.kill(recorded.pid, signal) == 0
    }
}
