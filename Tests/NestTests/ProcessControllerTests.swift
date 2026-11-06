import Foundation
import NestLib

/// ProcessController ordering and error handling, with every system boundary faked.
@MainActor
enum ProcessControllerTests {
    static func runAll() async -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 } else { failed += 1; print("  FAIL: \(message)") }
        }
        func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        }
        func settle() async {
            for _ in 0..<5 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(20))
        }
        func domains(_ sites: [Site]) -> String {
            sites.filter { $0.status == .running }.map(\.domain).joined(separator: ",")
        }

        let settings = AppSettings()
        let a = Site(name: "A", domain: "a.test", rootPath: "/tmp", documentRoot: ".", status: .running)
        let b = Site(name: "B", domain: "b.test", rootPath: "/tmp", documentRoot: ".", status: .running)

        // A site toggled while FrankenPHP starts is applied, with a reload, once it runs.
        do {
            var calls: [String] = []
            var resumeStart: CheckedContinuation<Void, Never>?
            var caddyUp = false
            var hooks = inertHooks()
            hooks.applyCaddy = { _, sites, _, running in
                calls.append("\(domains(sites)):\(running)")
                return running ? "Applied to Caddy" : "Saved • FrankenPHP stopped"
            }
            hooks.brew = { action, _ in
                calls.append("brew \(action.rawValue)")
                if action == .start { await withCheckedContinuation { resumeStart = $0 }; caddyUp = true }
            }
            hooks.isCaddyRunning = { caddyUp }
            let controller = ProcessController(hooks: hooks)
            controller.startFrankenPHP(settings: settings, sites: [a], projects: [])
            await waitFor { resumeStart != nil }
            controller.applyCaddy(settings: settings, sites: [a, b], projects: [])
            await settle()
            check(calls == ["a.test:false", "brew start"], "a toggle during FrankenPHP start waits instead of writing without a reload")
            resumeStart?.resume()
            await waitFor { calls.count == 3 && !controller.isServiceBusy("FrankenPHP") && !controller.caddyApplyState.isBusy }
            check(calls == ["a.test:false", "brew start", "a.test,b.test:true"], "the toggle is applied with a reload once FrankenPHP runs")
            check(controller.caddyApplyState == .applied("Applied to Caddy") && controller.frankenphpRunning,
                  "the latest sites, not the start's older snapshot, end up applied")
        }

        // Stopping FrankenPHP lets a reload in flight finish, then applies later edits without one.
        do {
            var calls: [String] = []
            var hold = true
            var resumeApply: CheckedContinuation<Void, Never>?
            var hooks = inertHooks()
            hooks.applyCaddy = { _, sites, _, running in
                calls.append("\(domains(sites)):\(running)")
                if hold { hold = false; await withCheckedContinuation { resumeApply = $0 } }
                return running ? "Applied to Caddy" : "Saved • FrankenPHP stopped"
            }
            hooks.brew = { action, _ in calls.append("brew \(action.rawValue)") }
            hooks.isCaddyRunning = { false }
            let controller = ProcessController(hooks: hooks)
            controller.frankenphpRunning = true
            controller.applyCaddy(settings: settings, sites: [a], projects: [])
            await waitFor { resumeApply != nil }
            controller.stopFrankenPHP()
            controller.applyCaddy(settings: settings, sites: [a, b], projects: [])
            await settle()
            check(calls == ["a.test:true"], "stop waits for the reload in flight")
            resumeApply?.resume()
            await waitFor { calls.count == 3 && !controller.isServiceBusy("FrankenPHP") && !controller.caddyApplyState.isBusy }
            check(calls == ["a.test:true", "brew stop", "a.test,b.test:false"], "the in-flight reload succeeds, then the edit is saved for the stopped server")
            check(controller.caddyApplyState == .applied("Saved • FrankenPHP stopped") && controller.frankenphpError == nil,
                  "no reload failure or rollback is reported")
        }

        // Identical Caddy output is not validated, written or reloaded again.
        do {
            var applies = 0
            var hooks = inertHooks()
            hooks.applyCaddy = { _, _, _, _ in applies += 1; return "Saved • FrankenPHP stopped" }
            let controller = ProcessController(hooks: hooks)
            var stopped = Site(name: "Old", domain: "old.test", rootPath: "/tmp", documentRoot: ".")
            controller.applyCaddy(settings: settings, sites: [a, stopped], projects: [])
            await waitFor { applies == 1 && controller.caddyApplyState == .applied("Saved • FrankenPHP stopped") }
            stopped.name = "Renamed"
            controller.applyCaddy(settings: settings, sites: [a, stopped], projects: [])
            controller.applyCaddy(settings: settings, sites: [a, stopped], projects: [])
            await settle()
            check(applies == 1 && controller.caddyApplyState == .applied("Saved • FrankenPHP stopped"), "renaming a stopped site is a no-op apply")
            stopped.status = .running
            controller.applyCaddy(settings: settings, sites: [a, stopped], projects: [])
            await waitFor { applies == 2 }
            check(applies == 2, "a change to the rendered Caddyfile is still applied")
        }

        // Projects reach Caddy through their local domain only; other project edits are no-op applies.
        do {
            var applied: [[String]] = []
            var hooks = inertHooks()
            hooks.applyCaddy = { _, _, projects, _ in
                applied.append(projects.compactMap(\.localDomain))
                return "Saved • FrankenPHP stopped"
            }
            let controller = ProcessController(hooks: hooks)
            var project = AppProject(name: "Vite", hostname: "vite.example.com", directory: "/tmp/vite", port: 5173)
            controller.applyCaddy(settings: settings, sites: [a], projects: [project])
            await waitFor { applied.count == 1 && controller.caddyApplyState == .applied("Saved • FrankenPHP stopped") }
            project.command = "npm run dev"
            controller.applyCaddy(settings: settings, sites: [a], projects: [project])
            await settle()
            check(applied.count == 1, "editing a project without a local domain does not touch Caddy")
            project.localDomain = "vite.test"
            controller.applyCaddy(settings: settings, sites: [a], projects: [project])
            await waitFor { applied.count == 2 }
            check(applied.last == ["vite.test"], "adding a local domain applies the project to Caddy")
            project.port = 5174
            controller.applyCaddy(settings: settings, sites: [a], projects: [project])
            await waitFor { applied.count == 3 }
            check(applied.count == 3, "a new port for a proxied project is applied")
        }

        // The PF administrator prompt is not repeated after a cancel; failures are visible.
        do {
            var allowed: [Bool] = []
            var outcomes: [PortRedirectRepairOutcome] = [.declined, .suppressed, .repaired]
            var hooks = inertHooks()
            hooks.isCaddyRunning = { true }
            hooks.repairPortRedirect = { allow in allowed.append(allow); return outcomes.isEmpty ? .notNeeded : outcomes.removeFirst() }
            let controller = ProcessController(hooks: hooks)
            controller.reconcileSystemNetworkState()
            await waitFor { controller.frankenphpError != nil }
            check(allowed == [true] && controller.frankenphpError == PortRedirectRepairOutcome.declined.message,
                  "a cancelled prompt is reported in the FrankenPHP error")
            controller.handleSystemWake()
            await waitFor { allowed.count == 2 }
            await settle()
            check(allowed == [true, false] && controller.frankenphpError == PortRedirectRepairOutcome.declined.message,
                  "wake does not show the prompt again this session")
            controller.retryPortRedirectRepair()
            await waitFor { allowed.count == 3 }
            await settle()
            check(allowed == [true, false, true] && controller.frankenphpError == nil, "an explicit retry may prompt again; success clears the error")
        }
        do {
            var allowed: [Bool] = []
            var caddyUp = true
            var status = ServiceStatusSnapshot(frankenphp: true, mariadb: false, cloudflared: false)
            var hooks = inertHooks()
            hooks.isCaddyRunning = { caddyUp }
            hooks.captureStatus = { _, _ in status }
            hooks.repairPortRedirect = { allow in allowed.append(allow); return .notWired }
            let controller = ProcessController(hooks: hooks)
            controller.reconcileSystemNetworkState()
            await waitFor { allowed.count == 1 }
            await settle()
            controller.reconcileSystemNetworkState()
            await waitFor { allowed.count == 2 }
            await settle()
            check(allowed == [true, true] && controller.frankenphpError?.contains("pf.conf") == true,
                  "missing pf.conf wiring is reported without suppressing a later prompt")
            controller.applyCaddy(settings: settings, sites: [a], projects: [])
            await waitFor { controller.caddyApplyState == .applied("Applied to Caddy") }
            check(controller.frankenphpError?.contains("pf.conf") == true, "a successful Caddy apply does not hide the broken redirect")
            caddyUp = false
            status.frankenphp = false
            controller.refreshStatusSnapshot(settings: settings, projects: [])
            await waitFor { controller.frankenphpError == nil }
            check(controller.frankenphpError == nil && !controller.frankenphpRunning, "the redirect error clears once FrankenPHP is stopped")
        }

        // Errors about whether a service runs clear once a refresh shows the opposite.
        do {
            var caddyUp = true
            var mariadbUp = true
            var status = ServiceStatusSnapshot(frankenphp: true, mariadb: true, cloudflared: false)
            var failApply = false
            var failBrewStart = false
            var hooks = inertHooks()
            hooks.isCaddyRunning = { caddyUp }
            hooks.isMariaDBRunning = { mariadbUp }
            hooks.captureStatus = { _, _ in status }
            hooks.brew = { action, _ in if action == .start, failBrewStart { throw ConfigurationFailure("brew start failed") } }
            hooks.applyCaddy = { _, _, _, _ in
                if failApply { throw ConfigurationFailure("Invalid Caddy configuration: bad") }
                return "Applied to Caddy"
            }
            let controller = ProcessController(hooks: hooks)
            func refresh() async {
                controller.refreshStatusSnapshot(settings: settings, projects: [])
                await settle()
            }
            controller.frankenphpRunning = true
            controller.mariadbRunning = true
            controller.stopFrankenPHP()
            controller.stopMariaDB()
            await waitFor { !controller.isServiceBusy("FrankenPHP") && !controller.isServiceBusy("MariaDB") }
            check(controller.frankenphpError?.contains("externally managed") == true && controller.mariadbError?.contains("externally managed") == true,
                  "an instance still running after stop is reported")
            await refresh()
            check(controller.frankenphpError != nil && controller.mariadbError != nil, "the errors stay while the instances still run")
            caddyUp = false; mariadbUp = false
            status = ServiceStatusSnapshot(frankenphp: false, mariadb: false, cloudflared: false)
            await refresh()
            check(controller.frankenphpError == nil && controller.mariadbError == nil, "\"still running\" errors clear once the services stop")

            failBrewStart = true
            controller.startFrankenPHP(settings: settings, sites: [a], projects: [])
            await waitFor { !controller.isServiceBusy("FrankenPHP") }
            check(controller.frankenphpError == "brew start failed", "a failed start is reported")
            await refresh()
            check(controller.frankenphpError == "brew start failed", "the start error stays while FrankenPHP is stopped")
            status.frankenphp = true
            await refresh()
            check(controller.frankenphpError == nil, "the start error clears once FrankenPHP runs")

            failApply = true
            controller.applyCaddy(settings: settings, sites: [a, b], projects: [])
            await waitFor { controller.frankenphpError?.contains("Invalid Caddy configuration") == true }
            status.frankenphp = false
            await refresh()
            status.frankenphp = true
            await refresh()
            check(controller.frankenphpError?.contains("Invalid Caddy configuration") == true, "configuration errors are not cleared by status changes")
        }

        var tunnelSettings = AppSettings()
        tunnelSettings.cloudflareSettings = CloudflareSettings(tunnelName: "t", configPath: "/tmp/c.yml", credentialsFilePath: "/tmp/c.json")
        var route = TunnelRoute(id: "route", kind: .php, subdomain: "first", publicDomain: "example.com", localDomain: "a.test", originPort: 443, active: false)

        // A route edit made while the connector stops is published after the stop, not dropped.
        do {
            var published: [String] = []
            var resumeStop: CheckedContinuation<Void, Never>?
            var hooks = inertHooks()
            hooks.stopConnector = {
                await withCheckedContinuation { resumeStop = $0 }
                return (CommandResult(status: 0, output: ""), false)
            }
            let controller = ProcessController(applyTunnel: { _, routes, _, _, running, _ in
                published.append("\(routes[0].subdomain):\(running)"); return "Applied"
            }, probeRoute: { _ in .reachable(200) }, hooks: hooks)
            // Only active routes reach cloudflared's configuration.
            var active = route
            active.active = true
            controller.markTunnelsPending(settings: tunnelSettings, routes: [active], sites: [], projects: [])
            controller.cloudflaredRunning = true
            controller.stopCloudflared()
            await waitFor { resumeStop != nil }
            active.subdomain = "edited"
            controller.markTunnelsPending(settings: tunnelSettings, routes: [active], sites: [], projects: [], automaticallyApply: true)
            await settle()
            check(published.isEmpty, "the edit waits for the stop in progress")
            resumeStop?.resume()
            await waitFor { published.count == 1 && !controller.isServiceBusy("Cloudflared") }
            // Automatic applies start the connector when a route is active, as they do after a stop.
            check(published == ["edited:true"], "the edit made during the stop is published once it finishes")
            controller.markTunnelsPending(settings: tunnelSettings, routes: [active], sites: [], projects: [], automaticallyApply: true)
            await settle()
            check(published.count == 1, "an unchanged configuration is not published again")
        }

        // Stop requested during an apply runs once the apply finishes.
        do {
            var stops = 0
            var resumeApply: CheckedContinuation<Void, Never>?
            var hooks = inertHooks()
            hooks.stopConnector = { stops += 1; return (CommandResult(status: 0, output: ""), false) }
            let controller = ProcessController(applyTunnel: { _, _, _, _, _, _ in
                if resumeApply == nil { await withCheckedContinuation { resumeApply = $0 } }
                return "Applied"
            }, probeRoute: { _ in .reachable(200) }, hooks: hooks)
            controller.applyTunnels(settings: tunnelSettings, routes: [route], sites: [], projects: [], push: false, start: true)
            await waitFor { resumeApply != nil }
            controller.stopCloudflared()
            await settle()
            check(stops == 0, "the stop waits for the apply in flight")
            resumeApply?.resume()
            await waitFor { stops == 1 && !controller.isServiceBusy("Cloudflared") }
            check(stops == 1 && !controller.cloudflaredRunning, "the stop is not dropped")
        }

        // An edit to a project that is still starting is applied once the start finishes.
        do {
            let jobs = FakeJobs()
            var hooks = inertHooks()
            hooks.projectLifecycle = { jobs.service() }
            let controller = ProcessController(hooks: hooks)
            let original = AppProject(id: "queued", name: "Queued", hostname: "queued.test", directory: "/tmp", port: 4301, command: "bun run dev")
            var edited = original
            edited.port = 4302
            controller.startProject(original)
            controller.restartProject(from: original, to: edited)
            jobs.gate.signal()
            await waitFor { jobs.startedPorts == [4301, 4302] && controller.projectOperation(for: original.id) == nil }
            check(jobs.startedPorts == [4301, 4302], "a restart requested during a start runs after it")
            check(controller.isProjectRunning(edited) && jobs.listeners(4301).isEmpty && jobs.listeners(4302) == [1001],
                  "the old port is released and the edited project runs")
            controller.stopProject(edited)
            controller.restartProject(from: edited, to: original)
            await waitFor { controller.projectOperation(for: original.id) == nil }
            await settle()
            check(jobs.startedPorts == [4301, 4302] && !controller.isProjectRunning(original), "an edit queued behind a stop does not restart the project")
        }

        // Public reachability retries ride out a connector restart, and stop when routes change.
        do {
            var probes: [RouteHealth] = [.httpError(530), .httpError(503), .reachable(200)]
            var count = 0
            let controller = ProcessController(probeRoute: { _ in
                count += 1
                return probes.isEmpty ? .httpError(530) : probes.removeFirst()
            }, hooks: inertHooks())
            controller.checkRoute(route, retry: true)
            await waitFor { controller.routeHealth[route.id] == .reachable(200) }
            check(count == 3 && controller.routeHealth[route.id] == .reachable(200), "530 and 503 after a connector restart are retried")
            count = 0
            controller.checkRoute(route, retry: true)
            await waitFor { controller.routeHealth[route.id] == .httpError(530) }
            check(count == 4, "a route that keeps failing is retried three times, then reported")
            count = 0
            controller.checkRoute(route)
            await waitFor { controller.routeHealth[route.id] == .httpError(530) }
            check(count == 1, "a manual check does not retry")

            var slow = inertHooks()
            slow.routeRetryDelays = [.seconds(5), .seconds(5), .seconds(5)]
            var slowCount = 0
            let cancelling = ProcessController(probeRoute: { _ in slowCount += 1; return .httpError(530) }, hooks: slow)
            cancelling.checkRoute(route, retry: true)
            await waitFor { slowCount == 1 }
            cancelling.markTunnelsPending(settings: tunnelSettings, routes: [], sites: [], projects: [])
            try? await Task.sleep(for: .milliseconds(50))
            check(slowCount == 1 && cancelling.routeHealth.isEmpty, "editing routes cancels pending retries")
        }

        // Legacy connector agents are retired once, at the first status refresh.
        do {
            var removals = 0
            var refreshes = 0
            var hooks = inertHooks()
            hooks.removeLegacyAgents = { removals += 1 }
            hooks.captureStatus = { _, _ in
                refreshes += 1
                return ServiceStatusSnapshot(frankenphp: false, mariadb: false, cloudflared: false)
            }
            let controller = ProcessController(hooks: hooks)
            controller.refreshStatusSnapshot(settings: settings, projects: [])
            await waitFor { refreshes == 1 }
            await settle()
            controller.refreshStatusSnapshot(settings: settings, projects: [])
            await waitFor { refreshes == 2 }
            check(removals == 1 && refreshes == 2, "legacy launch agents are removed once, before the first refresh")
        }

        return (passed, failed)
    }

    /// Hooks that never touch the Mac; each test replaces what it observes.
    static func inertHooks() -> ProcessController.SystemHooks {
        var hooks = ProcessController.SystemHooks()
        hooks.applyCaddy = { _, _, _, running in running ? "Applied to Caddy" : "Saved • FrankenPHP stopped" }
        hooks.brew = { _, _ in }
        hooks.isCaddyRunning = { false }
        hooks.isMariaDBRunning = { false }
        hooks.stopConnector = { (CommandResult(status: 0, output: ""), false) }
        hooks.captureStatus = { _, _ in ServiceStatusSnapshot(frankenphp: false, mariadb: false, cloudflared: false) }
        hooks.removeLegacyAgents = {}
        hooks.repairPortRedirect = { _ in .notNeeded }
        hooks.flushDNSCache = {}
        hooks.projectLifecycle = { FakeJobs.inert() }
        hooks.routeRetryDelays = [.milliseconds(1), .milliseconds(1), .milliseconds(1)]
        return hooks
    }
}

/// launchd jobs and listeners for project tests. The first start blocks until `gate` opens.
private final class FakeJobs: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var holdFirstStart = true
    private var ports: [Int: Int32] = [:]
    private var jobs: [String: (pid: Int32, port: Int)] = [:]
    private var started: [Int] = []

    var startedPorts: [Int] { lock.withLock { started } }
    func listeners(_ port: Int) -> [Int32] { lock.withLock { ports[port].map { [$0] } ?? [] } }

    func service() -> ProjectLifecycleService {
        ProjectLifecycleService(
            listeners: { self.listeners($0) },
            ownedPIDs: { label in self.lock.withLock { self.jobs[label].map { [$0.pid] } ?? [] } },
            compatibleLabels: { _ in [] },
            isAgentInstalled: { _ in false },
            startAgent: { self.start($0) },
            stopAgent: { label in
                self.lock.withLock { if let job = self.jobs.removeValue(forKey: label) { self.ports[job.port] = nil } }
                return .init(status: 0, output: "")
            },
            jobExit: { _ in nil }, processIdentity: { _ in nil }, signalProcess: { _, _ in },
            logTail: { _ in "" }, pause: { _ in })
    }

    private func start(_ definition: LaunchAgentDefinition) -> CommandResult {
        let hold = lock.withLock { () -> Bool in defer { holdFirstStart = false }; return holdFirstStart }
        if hold { gate.wait() }
        lock.withLock {
            let port = Int(definition.environment["PORT"] ?? "") ?? 0
            let pid = Int32(1000 + started.count)
            started.append(port)
            jobs[definition.label] = (pid, port)
            ports[port] = pid
        }
        return .init(status: 0, output: "")
    }

    /// A lifecycle whose start always fails and that never touches launchd or processes.
    static func inert() -> ProjectLifecycleService {
        ProjectLifecycleService(
            listeners: { _ in [] }, ownedPIDs: { _ in [] }, compatibleLabels: { _ in [] }, isAgentInstalled: { _ in false },
            startAgent: { _ in .init(status: 1, output: "inert") }, stopAgent: { _ in .init(status: 0, output: "") },
            jobExit: { _ in nil }, processIdentity: { _ in nil }, signalProcess: { _, _ in },
            logTail: { _ in "" }, pause: { _ in })
    }
}
