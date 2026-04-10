import Foundation

public struct CommandResult: Equatable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public enum SystemProcess {
    public static func capture(
        _ executablePath: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        if let environment {
            process.environment = environment
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return CommandResult(status: process.terminationStatus, output: output)
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }

    @discardableResult
    public static func run(
        _ executablePath: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil
    ) -> Int32 {
        capture(
            executablePath,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment
        ).status
    }
}
