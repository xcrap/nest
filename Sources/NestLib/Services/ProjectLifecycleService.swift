import Foundation
import Darwin

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
    /// Executable names of every process, so service checks need no separate `pgrep`.
    public var processNames: Set<String>

    public init(listeners: [Int: Set<Int32>], runningJobs: [String: Int32], children: [Int32: [Int32]],
                processNames: Set<String> = []) {
        self.listeners = listeners
        self.runningJobs = runningJobs
        self.children = children
        self.processNames = processNames
    }

    /// Three process launches at most: `launchctl list`, one `ps`, and `lsof` scoped to the
    /// watched ports (skipped when there are none).
    public static func capture(ports: [Int]) -> ProcessSnapshot {
        let jobs = LaunchAgentService.runningJobs()
        let table = LaunchAgentService.processTable()
        let listeners = ports.isEmpty ? [:] : PortInspector.listeningSockets(ports: ports)
        return .init(listeners: listeners, runningJobs: jobs, children: table.children, processNames: table.names)
    }

    public func processTree(label: String) -> Set<Int32> {
        guard let pid = runningJobs[label] else { return [] }
        return LaunchAgentService.processTree(root: pid, children: children)
    }

    public func isProcessRunning(named name: String) -> Bool { processNames.contains(name) }
}

public struct ProjectLifecycleService {
    public var listeners: (Int) -> [Int32]
    public var ownedPIDs: (String) -> Set<Int32>
    public var compatibleLabels: (ProjectLaunchPlan) -> [String]
    public var isAgentInstalled: (String) -> Bool
    public var startAgent: (LaunchAgentDefinition) -> CommandResult
    public var stopAgent: (String) -> CommandResult
    /// How a launchd job that already ran has ended, or nil while it runs or has not run yet.
    public var jobExit: (String) -> String?
    /// nil once the PID has exited; otherwise who it is, so a reused PID is never mistaken for it.
    public var processIdentity: (Int32) -> ProcessIdentity?
    public var signalProcess: (ProcessIdentity, Int32) -> Void
    /// The last lines of a log file, quoted when a project fails to start.
    public var logTail: (String) -> String
    public var pause: (TimeInterval) -> Void

    public init(listeners: @escaping (Int) -> [Int32] = PortInspector.pids,
                ownedPIDs: @escaping (String) -> Set<Int32> = LaunchAgentService.processTree,
                compatibleLabels: @escaping (ProjectLaunchPlan) -> [String] = { LaunchAgentService.compatibleProjectLabels(for: $0) },
                isAgentInstalled: @escaping (String) -> Bool = { LaunchAgentService.isInstalled(label: $0) },
                startAgent: @escaping (LaunchAgentDefinition) -> CommandResult = LaunchAgentService.start,
                stopAgent: @escaping (String) -> CommandResult = { LaunchAgentService.stop(label: $0) },
                jobExit: @escaping (String) -> String? = LaunchAgentService.exitDescription,
                processIdentity: @escaping (Int32) -> ProcessIdentity? = ProcessTable.identity,
                signalProcess: @escaping (ProcessIdentity, Int32) -> Void = { ProcessTable.signal($0, $1) },
                logTail: @escaping (String) -> String = { LogTailReader.read(path: $0, maxBytes: 2_048, maxLines: 6) },
                pause: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) {
        self.listeners = listeners; self.ownedPIDs = ownedPIDs
        self.compatibleLabels = compatibleLabels
        self.isAgentInstalled = isAgentInstalled
        self.startAgent = startAgent; self.stopAgent = stopAgent
        self.jobExit = jobExit
        self.processIdentity = processIdentity; self.signalProcess = signalProcess
        self.logTail = logTail
        self.pause = pause
    }

    /// Read-only status checks answered from a shared snapshot.
    public init(snapshot: ProcessSnapshot) {
        self.init(listeners: { Array(snapshot.listeners[$0] ?? []) },
                  ownedPIDs: { snapshot.processTree(label: $0) })
    }

    /// Start/stop polls spawn lsof, launchctl and ps: poll quickly at first, then back off.
    public static func pollInterval(attempt: Int) -> TimeInterval {
        [0.15, 0.25, 0.35, 0.5][min(max(attempt, 0), 3)]
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
        var attempt = 0
        repeat {
            let current = state(plan)
            if current.running || current.error != nil { return current }
            // A command that crashed is not going to start listening: report it now.
            if let exit = jobExit(plan.definition.label) {
                return .init(running: false, error: failure("\(plan.projectName) \(exit) before listening on port \(plan.port).", plan: plan))
            }
            pause(Self.pollInterval(attempt: attempt))
            attempt += 1
        } while Date() < deadline
        return .init(running: false, error: "Started \(plan.projectName), but its process did not begin listening on port \(plan.port). Check its log.")
    }

    /// launchd forgets a job as soon as it is booted out, while its processes may still be
    /// shutting down and holding the port. Wait for the processes it ran to exit, then
    /// escalate (SIGTERM, then SIGKILL) against those recorded processes only.
    public func stop(_ plan: ProjectLaunchPlan, timeout: TimeInterval = 5,
                     terminateGrace: TimeInterval = 2, killGrace: TimeInterval = 1) -> ProjectRuntimeState {
        var labels: [String] = []
        var recorded: [ProcessIdentity] = []
        for label in managedLabels(plan).sorted() {
            let pids = ownedPIDs(label)
            guard !pids.isEmpty || isAgentInstalled(label) else { continue }
            labels.append(label)
            recorded += pids.sorted().compactMap(processIdentity)
        }
        guard !labels.isEmpty else { return state(plan) }
        for label in labels {
            let result = stopAgent(label)
            guard result.status == 0 else { return .init(running: state(plan).running, error: "Could not stop \(plan.projectName): \(result.output)") }
        }
        func survivors() -> [ProcessIdentity] { recorded.filter { processIdentity($0.pid) == $0 } }
        func stopped() -> Bool { labels.allSatisfy { ownedPIDs($0).isEmpty } && survivors().isEmpty }

        if waitUntil(timeout, stopped) { return state(plan) }
        for signal in [(SIGTERM, terminateGrace), (SIGKILL, killGrace)] {
            let remaining = survivors()
            guard !remaining.isEmpty else { break }
            for process in remaining { signalProcess(process, signal.0) }
            if waitUntil(signal.1, stopped) { return state(plan) }
        }
        if stopped() { return state(plan) }
        // launchd may have forgotten the job, but a process it ran still holds on.
        return .init(running: state(plan).running || !survivors().isEmpty,
                     error: "\(plan.projectName) is still running after the stop request.")
    }

    /// Inactive jobs still launch at login, including those installed by the other build.
    public func hasInstalledAgent(_ plan: ProjectLaunchPlan) -> Bool {
        managedLabels(plan).contains(where: isAgentInstalled)
    }

    private func managedLabels(_ plan: ProjectLaunchPlan) -> Set<String> {
        Set([plan.definition.label] + compatibleLabels(plan))
    }

    /// Checks at least once, then polls with backoff until the deadline.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while !condition() {
            guard Date() < deadline else { return false }
            pause(min(Self.pollInterval(attempt: attempt), max(deadline.timeIntervalSinceNow, 0.01)))
            attempt += 1
        }
        return true
    }

    private func failure(_ message: String, plan: ProjectLaunchPlan) -> String {
        let log = logTail(plan.definition.standardErrorPath).trimmingCharacters(in: .whitespacesAndNewlines)
        return log.isEmpty ? message : "\(message)\n\nLast log lines:\n\(log)"
    }
}
