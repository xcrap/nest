import Foundation
import NestLib

enum ProjectLifecycleTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 }
            else { failed += 1; print("  FAIL: \(message)") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nest-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let project = AppProject(id: "webcams", name: "Webcams", hostname: "webcams.test", directory: directory.path, port: 3999, command: "bun run start")
            var plan = ProjectLaunchPlanner.plan(for: project)
            let primary = "app.nest.app-nest.project.webcams"
            let legacy = "app.nest.dev-nest-app.project.webcams"
            plan.definition.label = primary
            let file = directory.appendingPathComponent(legacy + ".plist")
            func writeJob(label: String = "app.nest.dev-nest-app.project.webcams", path: String, port: String = "3999") throws {
                let plist: [String: Any] = ["Label": label, "WorkingDirectory": path, "EnvironmentVariables": ["PORT": port]]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: file)
            }
            func compatible(_ plan: ProjectLaunchPlan) -> [String] {
                LaunchAgentService.compatibleProjectLabels(for: plan, directory: directory.path)
            }
            check(compatible(plan).isEmpty, "missing legacy job is not adopted")
            try writeJob(path: directory.path)
            check(compatible(plan) == [legacy], "same project in development namespace is recognized")
            try writeJob(path: directory.path + "/other")
            check(compatible(plan).isEmpty, "same ID in another directory is not adopted")
            try writeJob(path: directory.path, port: "4000")
            check(compatible(plan).isEmpty, "same ID on another port is not adopted")
            try writeJob(label: "unrelated.service", path: directory.path)
            check(compatible(plan).isEmpty, "mismatched plist label is rejected")
            try writeJob(path: directory.path)

            var listenerPIDs: [Int32] = [123]
            var jobs: [String: Set<Int32>] = [legacy: [123]]
            var starts = 0
            var stoppedLabels: [String] = []
            var failStop = false
            let service = ProjectLifecycleService(
                listeners: { _ in listenerPIDs },
                ownedPIDs: { jobs[$0] ?? [] },
                compatibleLabels: compatible,
                startAgent: { definition in
                    starts += 1
                    jobs[definition.label] = [456]
                    listenerPIDs = [456]
                    return .init(status: 0, output: "")
                },
                stopAgent: { label in
                    stoppedLabels.append(label)
                    if failStop { return .init(status: 1, output: "denied") }
                    listenerPIDs.removeAll { jobs[label]?.contains($0) == true }
                    jobs[label] = nil
                    return .init(status: 0, output: "")
                },
                jobExit: { _ in nil },
                // A fake PID is alive while a fake job owns it; never the real process table.
                processIdentity: { pid in jobs.values.contains { $0.contains(pid) } ? ProcessIdentity(pid: pid, startTime: 1, uid: 0) : nil },
                signalProcess: { _, _ in }, pause: { _ in })
            check(service.state(plan) == .init(running: true), "legacy listener is running without a port conflict")
            check(service.start(plan, timeout: 0).running && starts == 0, "Start does not duplicate the running legacy job")
            failStop = true
            let failure = service.stop(plan, timeout: 0)
            check(failure.running && failure.error?.contains("denied") == true, "failed legacy stop preserves running state and error")
            failStop = false
            stoppedLabels = []
            check(service.stop(plan, timeout: 0) == .init(running: false), "legacy job can be stopped")
            check(stoppedLabels == [legacy], "Stop targets the development job that owns the listener")
            check(service.start(plan, timeout: 0).running && jobs[primary] == [456], "next Start uses the packaged namespace")
            _ = service.stop(plan, timeout: 0)

            listenerPIDs = [789]
            stoppedLabels = []
            let conflict = service.start(plan, timeout: 0)
            check(!conflict.running && conflict.error?.contains("789") == true, "matching plist does not claim an unrelated port listener")
            _ = service.stop(plan, timeout: 0)
            check(stoppedLabels.isEmpty && listenerPIDs == [789], "unrelated listener remains untouched")
            jobs[legacy] = [123]
            listenerPIDs = [123, 789]
            check(service.state(plan).error?.contains("789") == true, "mixed owned and unrelated listeners still report a conflict")
            try writeJob(path: directory.path + "/other")
            listenerPIDs = [123]
            stoppedLabels = []
            _ = service.stop(plan, timeout: 0)
            check(stoppedLabels.isEmpty, "Stop does not control a same-ID job belonging to another folder")

            // Both builds' inactive jobs still run at login and must be removed before deletion.
            try writeJob(path: directory.path)
            let primaryFile = directory.appendingPathComponent(primary + ".plist")
            try Data().write(to: primaryFile)
            let unrelatedFile = directory.appendingPathComponent("unrelated.service.plist")
            try Data().write(to: unrelatedFile)
            var removeFiles = false
            stoppedLabels = []
            let inactive = ProjectLifecycleService(
                listeners: { _ in [789] }, ownedPIDs: { _ in [] }, compatibleLabels: compatible,
                isAgentInstalled: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0 + ".plist").path) },
                stopAgent: { label in
                    stoppedLabels.append(label)
                    if failStop { return .init(status: 1, output: "denied") }
                    if removeFiles { try? FileManager.default.removeItem(at: directory.appendingPathComponent(label + ".plist")) }
                    return .init(status: 0, output: "")
                },
                jobExit: { _ in nil }, processIdentity: { _ in nil }, signalProcess: { _, _ in }, pause: { _ in })
            check(inactive.hasInstalledAgent(plan), "deletion recognizes installed jobs even without any PIDs")
            failStop = true
            check(inactive.stop(plan, timeout: 0).error?.contains("denied") == true, "inactive job removal failures are reported")
            check(inactive.hasInstalledAgent(plan), "failed removal continues to block deletion")
            failStop = false
            _ = inactive.stop(plan, timeout: 0)
            check(inactive.hasInstalledAgent(plan), "a successful stop command alone does not prove login jobs were removed")
            removeFiles = true
            stoppedLabels = []
            _ = inactive.stop(plan, timeout: 0)
            check(Set(stoppedLabels) == Set([primary, legacy]), "Stop removes inactive jobs from both build namespaces")
            check(!inactive.hasInstalledAgent(plan), "deletion is allowed only after both login jobs are removed")
            check(FileManager.default.fileExists(atPath: unrelatedFile.path), "removing a project leaves unrelated launch agents alone")
            check(inactive.state(plan).error?.contains("789") == true, "an unrelated listener survives login job removal")
        } catch { check(false, "project lifecycle fixture: \(error)") }
        stopAndStartRegressions(directory: directory, check)
        return (passed, failed)
    }

    /// Stop waits for the processes launchd ran, start fails fast on a crash, and the
    /// helpers behind the status refresh parse what they need.
    private static func stopAndStartRegressions(directory: URL, _ check: (Bool, String) -> Void) {
        let project = AppProject(id: "stopper", name: "Stopper", hostname: "stopper.test", directory: directory.path, port: 4123, command: "bun run dev")
        let plan = ProjectLaunchPlanner.plan(for: project)
        let label = plan.definition.label

        var alive: [Int32: UInt64] = [:]
        var jobs: [String: Set<Int32>] = [:]
        var signals: [String] = []
        var pauses = 0
        var exitAfterPauses = Int.max
        var ignoresTerm = false
        var ignoresKill = false
        var afterBootout: () -> Void = {}
        func reset(_ pids: [Int32: UInt64]) {
            alive = pids; jobs = [label: Set(pids.keys)]; signals = []; pauses = 0
            exitAfterPauses = .max; ignoresTerm = false; ignoresKill = false; afterBootout = {}
        }
        // Fake PIDs only: nothing here reaches the real process table or kill().
        let service = ProjectLifecycleService(
            listeners: { _ in alive[10] == 7 ? [10] : [] },
            ownedPIDs: { jobs[$0] ?? [] },
            compatibleLabels: { _ in [] },
            isAgentInstalled: { _ in false },
            startAgent: { _ in .init(status: 0, output: "") },
            // launchd forgets the job at once; its processes exit on their own schedule.
            stopAgent: { jobs[$0] = nil; afterBootout(); return .init(status: 0, output: "") },
            jobExit: { _ in nil },
            processIdentity: { pid in alive[pid].map { ProcessIdentity(pid: pid, startTime: $0, uid: 0) } },
            signalProcess: { process, signal in
                signals.append("\(process.pid):\(signal == SIGKILL ? "KILL" : "TERM")")
                if signal == SIGKILL ? !ignoresKill : !ignoresTerm { alive[process.pid] = nil }
            },
            pause: { _ in
                pauses += 1
                if pauses >= exitAfterPauses { alive = [:] }
            })

        reset([10: 7, 11: 7])
        exitAfterPauses = 2
        check(service.stop(plan, timeout: 5) == .init(running: false), "stop reports stopped once the recorded processes exit")
        check(pauses == 2 && signals.isEmpty, "stop waits for processes still exiting after bootout instead of signalling them")

        reset([10: 7, 11: 7])
        ignoresTerm = true
        check(service.stop(plan, timeout: 0, terminateGrace: 0, killGrace: 0) == .init(running: false), "leftovers are killed so the port is released")
        check(signals == ["10:TERM", "11:TERM", "10:KILL", "11:KILL"], "SIGTERM comes before SIGKILL, for recorded PIDs only")

        reset([10: 7, 11: 7])
        // PID 11 exits and is reused by another process; PID 99 never belonged to the job.
        afterBootout = { alive[11] = 8; alive[99] = 1 }
        check(service.stop(plan, timeout: 0, terminateGrace: 0, killGrace: 0) == .init(running: false), "stop finishes once the recorded process is gone")
        check(signals == ["10:TERM"], "a reused PID and processes outside the job are never signalled")

        reset([10: 7])
        ignoresTerm = true
        ignoresKill = true
        let stuck = service.stop(plan, timeout: 0, terminateGrace: 0, killGrace: 0)
        check(stuck.running && stuck.error?.contains("still running") == true, "a process that survives SIGKILL is reported as running, not hidden")

        // A command that crashes is reported at once, with the end of its log.
        let log = directory.appendingPathComponent("crash.log")
        try? "booting\nerror: Cannot find module 'next'\n".write(to: log, atomically: true, encoding: .utf8)
        var crashPlan = plan
        crashPlan.definition.standardErrorPath = log.path
        var launched = false
        var exitChecks = 0
        let crashing = ProjectLifecycleService(
            listeners: { _ in [] }, ownedPIDs: { _ in [] }, compatibleLabels: { _ in [] }, isAgentInstalled: { _ in false },
            startAgent: { _ in launched = true; return .init(status: 0, output: "") },
            stopAgent: { _ in .init(status: 0, output: "") },
            jobExit: { _ in exitChecks += 1; return launched && exitChecks > 1 ? "exited with status 1" : nil },
            processIdentity: { _ in nil }, signalProcess: { _, _ in }, pause: { _ in })
        let began = Date()
        let crashed = crashing.start(crashPlan, timeout: 30)
        check(!crashed.running && crashed.error?.contains("Stopper exited with status 1 before listening on port 4123") == true,
              "a crashed command fails the start instead of waiting for the timeout")
        check(crashed.error?.contains("Cannot find module 'next'") == true, "the start failure quotes the last log lines")
        check(Date().timeIntervalSince(began) < 2, "a crashed command fails fast")

        var listening: [Int32] = []
        var polls = 0
        let slow = ProjectLifecycleService(
            listeners: { _ in listening }, ownedPIDs: { _ in [20] }, compatibleLabels: { _ in [] }, isAgentInstalled: { _ in false },
            startAgent: { _ in .init(status: 0, output: "") }, stopAgent: { _ in .init(status: 0, output: "") },
            jobExit: { _ in nil }, processIdentity: { _ in nil }, signalProcess: { _, _ in },
            pause: { _ in polls += 1; if polls == 3 { listening = [20] } })
        check(slow.start(plan, timeout: 30).running, "a job still running under launchd keeps being polled until it listens")
        check((0..<6).map(ProjectLifecycleService.pollInterval) == [0.15, 0.25, 0.35, 0.5, 0.5, 0.5], "start/stop polling backs off to 500 ms")

        // The real process table, against this test process only (signal 0 delivers nothing).
        if let me = ProcessTable.identity(of: getpid()) {
            check(me.uid == getuid() && me.startTime > 0, "a live process is identified with its owner and start time")
            check(ProcessTable.signal(me, 0), "the recorded process itself can be signalled")
            var reused = me
            reused.startTime += 1
            check(!ProcessTable.signal(reused, 0), "a PID whose start time changed (reused) is never signalled")
        } else {
            check(false, "the test process can be identified")
        }
        check(ProcessTable.identity(of: 1) == nil && ProcessTable.identity(of: -1) == nil, "launchd and invalid PIDs are never candidates")

        check(LaunchAgentService.parseJobExit("state = running\nruns = 1\nlast exit code = (never exited)") == nil, "a running job has not exited")
        check(LaunchAgentService.parseJobExit("\tstate = not running\n\truns = 1\n\tlast exit code = 127: Command not found") == "exited with status 127", "exit status is read from launchctl print")
        check(LaunchAgentService.parseJobExit("state = not running\nruns = 2\nlast terminating signal = Killed: 9") == "was terminated by Killed: 9", "terminating signal is reported")
        check(LaunchAgentService.parseJobExit("state = not running\nruns = 0") == nil, "a job that has not run yet has not exited")
        check(LaunchAgentService.parseJobExit("state = spawn scheduled\nruns = 1\nlast exit code = 1") == nil, "a job about to spawn is not treated as exited")

        let table = LaunchAgentService.parseProcessTable("    1     0 launchd\n  200     1 Google Chrome He\n  300   200 mariadbd\n")
        check(table.names.contains("mariadbd") && table.names.contains("Google Chrome He"), "process names (with spaces) come from the same ps call")
        check(table.children[1] == [200] && table.children[200] == [300], "the process tree comes from the same ps call")
        check(ProcessSnapshot(listeners: [:], runningJobs: [:], children: [:], processNames: table.names).isProcessRunning(named: "mariadbd"),
              "the snapshot answers the MariaDB check without pgrep")
        check(PortInspector.tcpSelector(ports: [3000, 80, 3000, 0, 70_000]) == "-iTCP:80,3000", "lsof is scoped to the watched ports")
        check(PortInspector.tcpSelector(ports: []) == nil && PortInspector.tcpSelector(ports: [0]) == nil, "no valid port never widens lsof to every port")

        // Status refreshes use the plan's identity without resolving the command (package.json).
        try? Data(#"{"dependencies":{"vite":"latest"}}"#.utf8).write(to: directory.appendingPathComponent("package.json"))
        var detected = project
        detected.command = ""
        let full = ProjectLaunchPlanner.plan(for: detected)
        let status = ProjectLaunchPlanner.statusPlan(for: detected)
        check(status.definition.label == full.definition.label && status.port == full.port
              && status.definition.workingDirectory == full.definition.workingDirectory
              && status.definition.environment["PORT"] == full.definition.environment["PORT"]
              && status.definition.standardErrorPath == full.definition.standardErrorPath,
              "the status plan identifies the same job, port, directory and log")
        check(status.definition.programArguments.isEmpty && !full.definition.programArguments.isEmpty, "the status plan skips command resolution")

        // A failed bootstrap must not leave a RunAtLoad plist that starts the project at login.
        let agents = directory.appendingPathComponent("agents").path
        let logPath = directory.appendingPathComponent("logs/out.log").path
        let definition = LaunchAgentDefinition(label: "app.nest.test.failing", programArguments: ["/usr/bin/true"],
                                               standardOutPath: logPath, standardErrorPath: logPath)
        let plist = agents + "/app.nest.test.failing.plist"
        var commands: [[String]] = []
        let failedStart = LaunchAgentService.start(definition, directory: agents, launchctl: { arguments in
            commands.append(arguments)
            if arguments.first == "bootstrap" { return .init(status: 5, output: "Bootstrap failed: 5: Input/output error") }
            return .init(status: arguments.first == "print" ? 113 : 0, output: "")
        }, pause: { _ in })
        check(failedStart.status == 5 && commands.filter { $0.first == "bootstrap" }.count == 5, "bootstrap failures are retried and reported")
        check(!FileManager.default.fileExists(atPath: plist), "a failed bootstrap removes the plist it wrote")
        let started = LaunchAgentService.start(definition, directory: agents, launchctl: { arguments in
            .init(status: arguments.first == "print" ? 113 : 0, output: "")
        }, pause: { _ in })
        check(started.status == 0 && FileManager.default.fileExists(atPath: plist), "a successful bootstrap keeps its plist")
    }
}
