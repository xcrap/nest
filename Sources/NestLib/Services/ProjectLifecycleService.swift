import Foundation

public struct ProjectRuntimeState: Equatable, Sendable {
    public var running: Bool
    public var error: String?
    public init(running: Bool, error: String? = nil) { self.running = running; self.error = error }
}

/// A point-in-time view of listening ports, launchd jobs and the process table.
/// Status refreshes use one of these for every project instead of querying per project.
public struct ProcessSnapshot: Sendable {
    public var listeners: [Int: Set<Int32>]
    public var runningJobs: [String: Int32]
    public var children: [Int32: [Int32]]

    public init(listeners: [Int: Set<Int32>], runningJobs: [String: Int32], children: [Int32: [Int32]]) {
        self.listeners = listeners
        self.runningJobs = runningJobs
        self.children = children
    }

    /// At most three process launches, and the process table only when a watched port is in use.
    public static func capture(ports: [Int]) -> ProcessSnapshot {
        let jobs = LaunchAgentService.runningJobs()
        guard !ports.isEmpty else { return .init(listeners: [:], runningJobs: jobs, children: [:]) }
        let listeners = PortInspector.listeningSockets()
        let needsTree = ports.contains { !(listeners[$0]?.isEmpty ?? true) }
        return .init(listeners: listeners, runningJobs: jobs, children: needsTree ? LaunchAgentService.childProcesses() : [:])
    }

    public func processTree(label: String) -> Set<Int32> {
        guard let pid = runningJobs[label] else { return [] }
        return LaunchAgentService.processTree(root: pid, children: children)
    }
}

public struct ProjectLifecycleService {
    public var listeners: (Int) -> [Int32]
    public var ownedPIDs: (String) -> Set<Int32>
    public var compatibleLabels: (ProjectLaunchPlan) -> [String]
    public var startAgent: (LaunchAgentDefinition) -> CommandResult
    public var stopAgent: (String) -> CommandResult

    public init(listeners: @escaping (Int) -> [Int32] = PortInspector.pids,
                ownedPIDs: @escaping (String) -> Set<Int32> = LaunchAgentService.processTree,
                compatibleLabels: @escaping (ProjectLaunchPlan) -> [String] = { LaunchAgentService.compatibleProjectLabels(for: $0) },
                startAgent: @escaping (LaunchAgentDefinition) -> CommandResult = LaunchAgentService.start,
                stopAgent: @escaping (String) -> CommandResult = { LaunchAgentService.stop(label: $0) }) {
        self.listeners = listeners; self.ownedPIDs = ownedPIDs
        self.compatibleLabels = compatibleLabels
        self.startAgent = startAgent; self.stopAgent = stopAgent
    }

    /// Read-only status checks answered from a shared snapshot.
    public init(snapshot: ProcessSnapshot) {
        self.init(listeners: { Array(snapshot.listeners[$0] ?? []) },
                  ownedPIDs: { snapshot.processTree(label: $0) })
    }

    public func state(_ plan: ProjectLaunchPlan) -> ProjectRuntimeState {
        let pids = Set(listeners(plan.port))
        // Nothing listening means not running; skip the launchd and process-table lookups.
        guard !pids.isEmpty else { return .init(running: false) }
        let owned = managedLabels(plan).reduce(into: Set<Int32>()) { $0.formUnion(ownedPIDs($1)) }
        if !pids.isEmpty && !pids.isSubset(of: owned) {
            return .init(running: false, error: "Port \(plan.port) is occupied by another process (PID \(pids.subtracting(owned).sorted().map(String.init).joined(separator: ", "))).")
        }
        return .init(running: !pids.isEmpty && !owned.isEmpty)
    }

    public func start(_ plan: ProjectLaunchPlan, timeout: TimeInterval = 12) -> ProjectRuntimeState {
        let initial = state(plan)
        guard initial.error == nil, !initial.running else { return initial }
        let result = startAgent(plan.definition)
        guard result.status == 0 else { return .init(running: false, error: result.output) }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let current = state(plan)
            if current.running || current.error != nil { return current }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return .init(running: false, error: "Started \(plan.projectName), but its process did not begin listening on port \(plan.port). Check its log.")
    }

    public func stop(_ plan: ProjectLaunchPlan, timeout: TimeInterval = 5) -> ProjectRuntimeState {
        let labels = managedLabels(plan).filter {
            !ownedPIDs($0).isEmpty || ($0 == plan.definition.label && LaunchAgentService.isInstalled(label: $0))
        }
        guard !labels.isEmpty else { return state(plan) }
        for label in labels {
            let result = stopAgent(label)
            guard result.status == 0 else { return .init(running: state(plan).running, error: "Could not stop \(plan.projectName): \(result.output)") }
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if labels.allSatisfy({ ownedPIDs($0).isEmpty }) { return state(plan) }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return .init(running: state(plan).running, error: "\(plan.projectName) is still running after the stop request.")
    }

    private func managedLabels(_ plan: ProjectLaunchPlan) -> Set<String> {
        Set([plan.definition.label] + compatibleLabels(plan))
    }
}
