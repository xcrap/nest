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

    @discardableResult
    public static func run(_ executablePath: String, arguments: [String] = [], currentDirectory: String? = nil,
                           environment: [String: String]? = nil) -> Int32 {
        capture(executablePath, arguments: arguments, currentDirectory: currentDirectory, environment: environment).status
    }
}
