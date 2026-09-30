import Foundation
import NestLib

@MainActor
enum RobustnessTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func assert(_ condition: Bool, _ msg: String, file: String = #file, line: Int = #line) {
            if condition {
                passed += 1
            } else {
                failed += 1
                print("  FAIL: \(msg) (\(file):\(line))")
            }
        }

        func fail(_ message: String, _ error: Error) {
            failed += 1
            print("  FAIL: \(message) threw: \(error)")
        }

        func store(in directory: URL) -> SiteStore {
            SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
        }

        func envelope(_ payload: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": StoreSchema.currentVersion, "savedAt": "2026-09-30T10:00:00Z", "payload": payload])
        }

        func siteJSON(id: String, domain: String, status: String = "running") -> [String: Any] {
            ["id": id, "name": id, "domain": domain, "rootPath": "/Users/test/\(id)", "documentRoot": ".",
             "status": status, "createdAt": "2026-09-30T10:00:00Z", "updatedAt": "2026-09-30T10:00:00Z"]
        }

        // Test: one unreadable record is skipped instead of emptying the whole list.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try envelope([
                siteJSON(id: "a", domain: "a.test"),
                siteJSON(id: "b", domain: "b.test", status: "paused"),
                siteJSON(id: "c", domain: "c.test")
            ]).write(to: directory.appendingPathComponent("sites.json"))

            let loaded = store(in: directory)
            assert(loaded.sites.map(\.id) == ["a", "c"], "should keep every readable site")
            assert(loaded.persistenceErrors.contains { $0.contains("1 sites record(s) could not be read") }, "should report skipped records")
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            assert(names.contains { $0.hasPrefix("sites.json.invalid-") }, "should back up the original file")
        } catch { fail("lossy site load", error) }

        // Test: a file that cannot be parsed at all is never overwritten.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let corrupt = Data("{not valid json".utf8)
            try corrupt.write(to: directory.appendingPathComponent("sites.json"))

            let loaded = store(in: directory)
            assert(loaded.unreadableFiles.contains(.sites), "should flag the unreadable file")
            _ = loaded.addSite(name: "New", domain: "new", rootPath: "/Users/test/new", documentRoot: ".")
            assert(loaded.saveError(.sites) != nil, "should refuse to save over an unreadable file")
            assert(try Data(contentsOf: directory.appendingPathComponent("sites.json")) == corrupt, "should leave the original bytes untouched")
        } catch { fail("unreadable file protection", error) }

        // Test: a newer schema is not downgraded by an older app.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let newer = try JSONSerialization.data(withJSONObject: ["schemaVersion": StoreSchema.currentVersion + 1, "savedAt": "2026-09-30T10:00:00Z", "payload": []])
            try newer.write(to: directory.appendingPathComponent("projects.json"))
            let loaded = store(in: directory)
            assert(loaded.unreadableFiles.contains(.projects), "should not overwrite newer schema files")
        } catch { fail("newer schema protection", error) }

        // Test: an envelope whose payload fails is not reinterpreted as legacy settings (which reset to defaults).
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try envelope(["hasCompletedMindMigration": "not a bool"]).write(to: directory.appendingPathComponent("settings.json"))
            let loaded = store(in: directory)
            assert(loaded.unreadableFiles.contains(.settings), "should flag broken settings envelopes")
            assert(!loaded.persistenceErrors.contains { $0.contains("Migrated legacy settings") }, "should not treat an envelope as legacy data")
        } catch { fail("settings envelope protection", error) }

        // Test: legacy settings are migrated once, not backed up again on every launch.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings(mindProjectDirectory: "/tmp/mind"))) as! [String: Any]
            try JSONSerialization.data(withJSONObject: legacy).write(to: directory.appendingPathComponent("settings.json"))
            _ = store(in: directory)
            _ = store(in: directory)
            let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("settings.json.legacy-") }
            assert(backups.count == 1, "should back up legacy settings only once")
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("settings.json"))) as? [String: Any]
            assert(saved?["schemaVersion"] != nil, "should save migrated settings as an envelope")
        } catch { fail("legacy settings migration", error) }

        // Test: project IDs never collide, so launch agents and logs stay separate.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let projects = store(in: directory)
            var blog = projects.addProject(name: "Blog", hostname: "blog.example.com", directory: "/tmp/blog", port: 3000, command: "")
            blog.name = "Old Blog"
            projects.updateProject(blog)
            let second = projects.addProject(name: "Blog", hostname: "new.example.com", directory: "/tmp/new", port: 3001, command: "")
            let third = projects.addProject(name: "BLOG!", hostname: "third.example.com", directory: "/tmp/third", port: 3002, command: "")
            assert(Set([blog.id, second.id, third.id]).count == 3, "should give each project a distinct ID")
            assert(Set([blog.launchAgentLabel, second.launchAgentLabel, third.launchAgentLabel]).count == 3, "should give each project its own launch agent")
            projects.deleteProject(id: second.id)
            assert(projects.appProjects.map(\.id).sorted() == [blog.id, third.id].sorted(), "deleting one project should keep the others")
        }

        // Test: existing duplicate IDs are repaired on load.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let project: (String, String) -> [String: Any] = { name, host in
                ["id": "blog", "name": name, "hostname": host, "directory": "/tmp/\(name)", "port": 3000, "command": "",
                 "createdAt": "2026-09-30T10:00:00Z", "updatedAt": "2026-09-30T10:00:00Z"]
            }
            try envelope([project("one", "one.example.com"), project("two", "two.example.com")])
                .write(to: directory.appendingPathComponent("projects.json"))
            let loaded = store(in: directory)
            assert(loaded.appProjects.map(\.id) == ["blog", "blog-2"], "should keep the first ID and rename later duplicates")
            assert(store(in: directory).appProjects.map(\.id) == ["blog", "blog-2"], "should persist the repaired IDs")
        } catch { fail("duplicate ID repair", error) }

        // Test: new tunnel routes never reuse an existing route's ID.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let routes = store(in: directory)
            routes.addTunnelRoute(TunnelRoute(id: "staging", kind: .app, subdomain: "staging", publicDomain: "example.com", localDomain: "a.example.com", originPort: 3000))
            routes.addTunnelRoute(TunnelRoute(id: "staging", kind: .app, subdomain: "preview", publicDomain: "example.com", localDomain: "b.example.com", originPort: 3001))
            assert(Set(routes.tunnelRoutes.map(\.id)).count == 2, "should keep route IDs unique")
            routes.deleteTunnelRoute(id: "staging")
            assert(routes.tunnelRoutes.count == 1, "deleting one route should keep the other")
        }

        // Test: renaming a site keeps its tunnel route linked.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let linked = store(in: directory)
            var site = linked.addSite(name: "Shop", domain: "shop", rootPath: "/Users/test/shop", documentRoot: ".")
            linked.addTunnelRoute(TunnelRoute(kind: .php, subdomain: "shop", publicDomain: "example.com", localDomain: "shop.test", originPort: 443, linkedSiteDomain: "shop.test"))
            site.domain = "store.test"
            linked.updateSite(site)
            assert(linked.tunnelRoutes.first?.linkedSiteDomain == "store.test", "should follow the renamed site")
            assert(linked.tunnelRoutes.first?.localDomain == "store.test", "should update the route's local domain")
        }

        // Test: routes link by explicit ID or hostname, never by a shared port.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let linking = store(in: directory)
            let first = linking.addProject(name: "First", hostname: "first.example.com", directory: "/tmp/first", port: 3000, command: "")
            let second = linking.addProject(name: "Second", hostname: "second.example.com", directory: "/tmp/second", port: 3000, command: "")
            linking.addTunnelRoute(TunnelRoute(kind: .app, subdomain: "manual", publicDomain: "example.com", localDomain: "api.other.dev", originPort: 3000))
            linking.addTunnelRoute(TunnelRoute(kind: .app, subdomain: "explicit", publicDomain: "example.com", localDomain: "second.example.com", originPort: 3000, linkedProjectID: second.id))
            linking.addTunnelRoute(TunnelRoute(kind: .app, subdomain: "byhost", publicDomain: "example.com", localDomain: "first.example.com", originPort: 9999))
            let route: (String) -> TunnelRoute? = { sub in linking.tunnelRoutes.first { $0.subdomain == sub } }
            assert(route("manual")?.linkedProjectID == nil, "should not link a manual route by port alone")
            assert(route("explicit")?.linkedProjectID == second.id, "should keep an explicit link even when another project shares the port")
            assert(route("byhost")?.linkedProjectID == first.id, "should link by hostname")
        }

        // Test: a deferred store never touches the credential store until asked (nestctl).
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let credentials = CountingCredentials(token: "secret")
            let deferred = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false,
                                     credentialStore: credentials, loadsCredential: false)
            assert(credentials.loads == 0, "should not read credentials at init")
            deferred.loadCredentialIfNeeded()
            deferred.loadCredentialIfNeeded()
            assert(credentials.loads == 1 && deferred.settings.cloudflareSettings.apiToken == "secret", "should read credentials once, on demand")
        }

        // Test: a Keychain read failure is not a save error, so unrelated saves stay enabled.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let failing = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false,
                                    credentialStore: CountingCredentials(token: "", failLoads: true))
            assert(failing.credentialError != nil, "should report the Keychain read failure")
            assert(failing.saveError(.settings) == nil && failing.saveError(.sites) == nil, "should not mark files as failing to save")
            _ = failing.addSite(name: "A", domain: "a", rootPath: "/Users/test/a", documentRoot: ".")
            assert(failing.lastSaveError == nil, "site saves should still work")
        }

        // Test: single-call process snapshots are parsed correctly.
        do {
            let sockets = PortInspector.parseListeningSockets("p672\nf11\nn*:49181\nf12\nn*:49181\np748\nf10\nn127.0.0.1:7000\nf13\nn[::1]:5000\n")
            assert(sockets[49181] == [672], "should map a port to its process")
            assert(sockets[7000] == [748] && sockets[5000] == [748], "should parse IPv4 and IPv6 listeners")

            let jobs = LaunchAgentService.parseRunningJobs("PID\tStatus\tLabel\n5632\t0\tapp.nest.app-nest.project.a\n-\t78\tapp.nest.app-nest.project.b\n")
            assert(jobs == ["app.nest.app-nest.project.a": 5632], "should only list jobs with a PID as running")

            let children = LaunchAgentService.parseChildProcesses("  100     1\n  200   100\n  300   200\n  400     1\n")
            assert(LaunchAgentService.processTree(root: 100, children: children) == [100, 200, 300], "should collect the whole process tree")

            let project = AppProject(id: "a", name: "A", hostname: "a.example.com", directory: "/tmp/a", port: 3000)
            let plan = ProjectLaunchPlanner.plan(for: project, launchPath: "/usr/bin")
            let owned = ProcessSnapshot(listeners: [3000: [300]], runningJobs: [project.launchAgentLabel: 100], children: children)
            assert(ProjectLifecycleService(snapshot: owned).state(plan).running, "a listener in the agent's tree is running")
            let foreign = ProcessSnapshot(listeners: [3000: [400]], runningJobs: [project.launchAgentLabel: 100], children: children)
            assert(ProjectLifecycleService(snapshot: foreign).state(plan).error?.contains("another process") == true, "a foreign listener is a conflict")
            let idle = ProcessSnapshot(listeners: [:], runningJobs: [:], children: [:])
            assert(ProjectLifecycleService(snapshot: idle).state(plan) == ProjectRuntimeState(running: false), "nothing listening means stopped")
        }

        // Test: dnsmasq and resolver checks agree on the port actually served.
        do {
            let includes: (String) -> [String] = { _ in [] }
            let nest = PrerequisiteChecker.parseDnsmasqConfiguration("port=5354\naddress=/.test/127.0.0.1\n", includedFiles: includes)
            assert(nest == .init(port: 5354, resolvesTestDomains: true), "should read Nest's own dnsmasq config")
            let commented = PrerequisiteChecker.parseDnsmasqConfiguration("#address=/.test/127.0.0.1\n", includedFiles: includes)
            assert(!commented.resolvesTestDomains, "should ignore commented-out entries")

            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "address=/.test/127.0.0.1\n".write(to: directory.appendingPathComponent("valet.conf"), atomically: true, encoding: .utf8)
            let valet = PrerequisiteChecker.parseDnsmasqConfiguration("conf-dir=\(directory.path),*.conf\n")
            assert(valet == .init(port: 53, resolvesTestDomains: true), "should follow conf-dir includes and default to port 53")
            assert(PrerequisiteChecker.expectedResolverPort(dnsmasq: valet) == 53, "resolver should target dnsmasq's real port")
            assert(PrerequisiteChecker.expectedResolverPort(dnsmasq: nil) == 5354, "unconfigured setups use Nest's port")
            assert(PrerequisiteChecker.resolverPort("nameserver 127.0.0.1\nport 5354\n") == 5354, "should read the resolver port")
            assert(PrerequisiteChecker.resolverPort("nameserver 127.0.0.1\n") == 53, "resolver port defaults to 53")
            assert(PrerequisiteChecker.resolverPort("nameserver 10.0.0.1\n") == nil, "should require a local nameserver")
        } catch { fail("dnsmasq parsing", error) }

        // Test: the redirect probe only accepts Caddy.
        do {
            assert(LocalRedirectProbe.isCaddyResponse(headers: "HTTP/1.1 308 Permanent Redirect\r\nLocation: https://localhost/\r\nServer: FrankenPHP Caddy\r\n"), "should accept Caddy")
            assert(LocalRedirectProbe.isCaddyResponse(headers: "HTTP/1.1 308 Permanent Redirect\r\nLocation: https://localhost/\r\n"), "should accept Caddy's HTTPS redirect without a Server header")
            assert(!LocalRedirectProbe.isCaddyResponse(headers: "HTTP/1.1 200 OK\r\nServer: nginx\r\n"), "should reject another web server")
        }

        // Test: Auto-Detect never clears API credentials.
        do {
            let current = CloudflareSettings(apiToken: "token", zoneId: "zone", accountId: "account", tunnelId: "old", tunnelName: "old", configPath: "/custom/config.yml")
            let detected = CloudflareSettings(tunnelId: "new-id", tunnelName: "new", tunnelDomain: "new-id.cfargotunnel.com", configPath: "/nonexistent/config.yml")
            let merged = current.mergingDetected(detected)
            assert(merged.apiToken == "token" && merged.zoneId == "zone" && merged.accountId == "account", "should keep API credentials")
            assert(merged.tunnelName == "new" && merged.tunnelId == "new-id", "should apply detected tunnel values")
            assert(merged.configPath == "/custom/config.yml", "should not replace a custom config path with a missing file")
        }

        // Test: the /tmp trigger file never follows a planted symlink.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let victim = directory.appendingPathComponent("victim")
            try "keep me".write(to: victim, atomically: true, encoding: .utf8)
            let link = directory.appendingPathComponent("kick")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
            assert(!PFHelperManager.touchKickFile(at: link.path), "should refuse a symlinked trigger file")
            assert(try String(contentsOf: victim, encoding: .utf8) == "keep me", "should leave the symlink target untouched")
            let regular = directory.appendingPathComponent("regular")
            assert(PFHelperManager.touchKickFile(at: regular.path), "should write a regular trigger file")
        } catch { fail("trigger file safety", error) }

        // Test: tunnels only become pending when the cloudflared config would change.
        do {
            let controller = ProcessController()
            var settings = AppSettings()
            settings.cloudflareSettings = CloudflareSettings(tunnelName: "t", configPath: "/tmp/c.yml", credentialsFilePath: "/tmp/c.json")
            let site = Site(name: "A", domain: "a.test", rootPath: "/Users/test/a")
            let route = TunnelRoute(kind: .php, subdomain: "a", publicDomain: "example.com", localDomain: "a.test", originPort: 443, linkedSiteDomain: "a.test")
            controller.markTunnelsPending(settings: settings, routes: [route], sites: [site], projects: [])
            controller.tunnelApplyState = .applied("done")
            var toggled = site
            toggled.status = .running
            toggled.updatedAt = Date().addingTimeInterval(60)
            controller.markTunnelsPending(settings: settings, routes: [route], sites: [toggled], projects: [])
            assert(controller.tunnelApplyState == .applied("done"), "a site toggle should not require re-applying tunnels")
            var moved = route
            moved.originPort = 8443
            controller.markTunnelsPending(settings: settings, routes: [moved], sites: [toggled], projects: [])
            assert(controller.tunnelApplyState == .pending, "a route change should require re-applying tunnels")
        }

        return (passed, failed)
    }

    private static func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nest-robustness-\(UUID().uuidString)", isDirectory: true)
    }

    private final class CountingCredentials: CredentialStore {
        var token: String
        let failLoads: Bool
        var loads = 0
        init(token: String, failLoads: Bool = false) { self.token = token; self.failLoads = failLoads }
        func load() throws -> String {
            loads += 1
            if failLoads { throw ConfigurationFailure("Keychain read denied") }
            return token
        }
        func save(_ token: String) throws { self.token = token }
    }
}
