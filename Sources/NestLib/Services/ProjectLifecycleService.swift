import Foundation

public struct ProjectRuntimeState: Equatable, Sendable {
    public var running: Bool
    public var error: String?
    public init(running: Bool, error: String? = nil) { self.running = running; self.error = error }
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

    public func state(_ plan: ProjectLaunchPlan) -> ProjectRuntimeState {
        let pids = Set(listeners(plan.port))
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
