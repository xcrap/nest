import Foundation
import Darwin

public struct LaunchAgentDefinition {
    public var label: String
    public var programArguments: [String]
    public var workingDirectory: String?
    public var environment: [String: String]
    public var standardOutPath: String
    public var standardErrorPath: String
    public var keepAlive: Bool

    public init(
        label: String,
        programArguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        standardOutPath: String,
        standardErrorPath: String,
        keepAlive: Bool = true
    ) {
        self.label = label
        self.programArguments = programArguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardOutPath = standardOutPath
        self.standardErrorPath = standardErrorPath
        self.keepAlive = keepAlive
    }
}

public enum LaunchAgentService {
    public static var launchAgentsDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
    }

    public static var domainTarget: String {
        "gui/\(getuid())"
    }

    public static func plistPath(for label: String) -> String {
        (launchAgentsDirectory as NSString).appendingPathComponent("\(label).plist")
    }

    public static func serviceTarget(for label: String) -> String {
        "\(domainTarget)/\(label)"
    }

    @discardableResult
    public static func start(_ definition: LaunchAgentDefinition) -> CommandResult {
        do {
            try write(definition)
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }

        let plistPath = plistPath(for: definition.label)
        let serviceTarget = serviceTarget(for: definition.label)
        _ = SystemProcess.capture("/bin/launchctl", arguments: ["enable", serviceTarget])
        _ = SystemProcess.capture("/bin/launchctl", arguments: ["bootout", serviceTarget])
        _ = SystemProcess.capture("/bin/launchctl", arguments: ["bootout", domainTarget, plistPath])
        let bootstrap = SystemProcess.capture("/bin/launchctl", arguments: ["bootstrap", domainTarget, plistPath])
        if bootstrap.status != 0 {
            return bootstrap
        }

        return SystemProcess.capture(
            "/bin/launchctl",
            arguments: ["kickstart", "-k", serviceTarget]
        )
    }

    @discardableResult
    public static func stop(label: String, removePlist: Bool = true) -> CommandResult {
        let plistPath = plistPath(for: label)
        let serviceTarget = serviceTarget(for: label)
        _ = SystemProcess.capture("/bin/launchctl", arguments: ["disable", serviceTarget])

        var result = SystemProcess.capture("/bin/launchctl", arguments: ["bootout", serviceTarget])
        if result.status != 0 {
            result = SystemProcess.capture("/bin/launchctl", arguments: ["bootout", domainTarget, plistPath])
        }

        if removePlist {
            try? FileManager.default.removeItem(atPath: plistPath)
        }

        return result
    }

    public static func isInstalled(label: String) -> Bool {
        FileManager.default.fileExists(atPath: plistPath(for: label))
    }

    private static func write(_ definition: LaunchAgentDefinition) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: launchAgentsDirectory, withIntermediateDirectories: true)

        let outDirectory = (definition.standardOutPath as NSString).deletingLastPathComponent
        let errDirectory = (definition.standardErrorPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: outDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: errDirectory, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "Label": definition.label,
            "ProgramArguments": definition.programArguments,
            "RunAtLoad": true,
            "KeepAlive": definition.keepAlive,
            "StandardOutPath": definition.standardOutPath,
            "StandardErrorPath": definition.standardErrorPath,
        ]

        if let workingDirectory = definition.workingDirectory {
            plist["WorkingDirectory"] = workingDirectory
        }

        if !definition.environment.isEmpty {
            plist["EnvironmentVariables"] = definition.environment
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        try data.write(to: URL(fileURLWithPath: plistPath(for: definition.label)), options: .atomic)
    }
}
