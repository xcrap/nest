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
        if isLoaded(label: definition.label) {
            _ = SystemProcess.capture("/bin/launchctl", arguments: ["bootout", serviceTarget])
            _ = SystemProcess.capture("/bin/launchctl", arguments: ["bootout", domainTarget, plistPath])
            // bootout returns before launchd has torn the job down; bootstrapping early fails.
            let deadline = Date().addingTimeInterval(5)
            while isLoaded(label: definition.label) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        // RunAtLoad starts the job on bootstrap, so no kickstart is needed (it would restart it).
        var bootstrap = CommandResult(status: -1, output: "launchctl bootstrap did not run.")
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.3) }
            bootstrap = SystemProcess.capture("/bin/launchctl", arguments: ["bootstrap", domainTarget, plistPath])
            if bootstrap.status == 0 { break }
        }
        return bootstrap
    }

    public static func isLoaded(label: String) -> Bool {
        SystemProcess.capture("/bin/launchctl", arguments: ["print", serviceTarget(for: label)], timeout: 3).status == 0
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
        return processTree(root: pid, children: childProcesses())
    }

    /// Main PIDs of every running job in the user's launchd domain, from a single `launchctl list`.
    public static func runningJobs() -> [String: Int32] {
        let result = SystemProcess.capture("/bin/launchctl", arguments: ["list"], timeout: 3)
        guard result.status == 0 else { return [:] }
        return parseRunningJobs(result.output)
    }

    /// Parses `launchctl list` rows (`PID<TAB>Status<TAB>Label`); jobs without a PID are not running.
    public static func parseRunningJobs(_ output: String) -> [String: Int32] {
        var jobs: [String: Int32] = [:]
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3, let pid = Int32(columns[0]) else { continue }
            jobs[String(columns[2])] = pid
        }
        return jobs
    }

    /// Parent → children map for every process, from a single `ps` call.
    public static func childProcesses() -> [Int32: [Int32]] {
        let table = SystemProcess.capture("/bin/ps", arguments: ["-axo", "pid=,ppid="], timeout: 3)
        guard table.status == 0 else { return [:] }
        return parseChildProcesses(table.output)
    }

    public static func parseChildProcesses(_ output: String) -> [Int32: [Int32]] {
        var children: [Int32: [Int32]] = [:]
        for line in output.split(separator: "\n") {
            let values = line.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
            guard values.count == 2 else { continue }
            children[values[1], default: []].append(values[0])
        }
        return children
    }

    public static func processTree(root: Int32, children: [Int32: [Int32]]) -> Set<Int32> {
        var tree: Set<Int32> = [root]
        var pending = [root]
        while let pid = pending.popLast() {
            for child in children[pid] ?? [] where tree.insert(child).inserted {
                pending.append(child)
            }
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
