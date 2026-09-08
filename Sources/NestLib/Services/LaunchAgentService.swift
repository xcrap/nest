import Foundation
import Darwin

public struct LaunchAgentDefinition: Sendable {
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
        let inspection = SystemProcess.capture("/bin/launchctl", arguments: ["print", serviceTarget], timeout: 3)
        if inspection.status != 0 {
            guard inspection.output.contains("Could not find service") else { return inspection }
            if removePlist, FileManager.default.fileExists(atPath: plistPath) {
                do { try FileManager.default.removeItem(atPath: plistPath) }
                catch { return CommandResult(status: -1, output: error.localizedDescription) }
            }
            return CommandResult(status: 0, output: "Service is already stopped.")
        }
        _ = SystemProcess.capture("/bin/launchctl", arguments: ["disable", serviceTarget])

        var result = SystemProcess.capture("/bin/launchctl", arguments: ["bootout", serviceTarget])
        if result.status != 0 {
            result = SystemProcess.capture("/bin/launchctl", arguments: ["bootout", domainTarget, plistPath])
        }

        if removePlist && result.status == 0 && FileManager.default.fileExists(atPath: plistPath) {
            do { try FileManager.default.removeItem(atPath: plistPath) }
            catch { return CommandResult(status: -1, output: error.localizedDescription) }
        }

        return result
    }

    public static func isInstalled(label: String) -> Bool {
        FileManager.default.fileExists(atPath: plistPath(for: label))
    }

    public static func isRunning(label: String) -> Bool {
        let result = SystemProcess.capture(
            "/bin/launchctl",
            arguments: ["print", serviceTarget(for: label)], timeout: 3
        )
        return result.status == 0 && result.output.contains("state = running")
    }

    /// A project may still be running under the other Nest build's namespace.
    /// Require the same project ID, directory and port before recognizing that job.
    public static func compatibleProjectLabels(for plan: ProjectLaunchPlan, directory: String = launchAgentsDirectory) -> [String] {
        let projectID = plan.projectID.lowercased().replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
        guard let workingDirectory = plan.definition.workingDirectory, !workingDirectory.isEmpty else { return [] }
        let expectedDirectory = URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().standardizedFileURL
        return ["app.nest.app-nest.project.", "app.nest.dev-nest-app.project."].compactMap { prefix in
            let label = prefix + projectID
            guard label != plan.definition.label,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(label + ".plist")),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  plist["Label"] as? String == label,
                  let path = plist["WorkingDirectory"] as? String, !path.isEmpty,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL == expectedDirectory,
                  let environment = plist["EnvironmentVariables"] as? [String: String],
                  environment["PORT"] == String(plan.port) else { return nil }
            return label
        }
    }

    /// Only the process tree registered under this exact launchd label is owned by Nest.
    public static func processTree(label: String) -> Set<Int32> {
        let result = SystemProcess.capture("/bin/launchctl", arguments: ["print", serviceTarget(for: label)], timeout: 3)
        guard result.status == 0,
              let line = result.output.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }),
              let pid = Int32(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") else { return [] }
        let table = SystemProcess.capture("/bin/ps", arguments: ["-axo", "pid=,ppid="], timeout: 3)
        let pairs = table.output.split(separator: "\n").compactMap { line -> (Int32, Int32)? in
            let values = line.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
            return values.count == 2 ? (values[0], values[1]) : nil
        }
        var tree: Set<Int32> = [pid]
        var previous = 0
        while tree.count != previous {
            previous = tree.count
            for (child, parent) in pairs where tree.contains(parent) { tree.insert(child) }
        }
        return tree
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
            "AbandonProcessGroup": false,
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
