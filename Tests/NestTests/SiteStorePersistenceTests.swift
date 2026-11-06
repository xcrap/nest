import Foundation
import NestLib

@MainActor
enum SiteStorePersistenceTests {
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

        // Test: corrupt JSON is reported and backed up instead of being silently ignored.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sitesFile = directory.appendingPathComponent("sites.json")
            try Data("{not valid json".utf8).write(to: sitesFile)

            let store = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            assert(store.sites.isEmpty, "should fall back to an empty site list")
            assert(store.persistenceErrors.contains { $0.contains("Cannot decode sites") }, "should report decode errors")

            let filenames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            assert(filenames.contains { $0.hasPrefix("sites.json.invalid-") }, "should create an invalid-file backup")
        } catch {
            failed += 1
            print("  FAIL: corrupt JSON persistence test threw: \(error)")
        }

        // Test: store normalizes saved records and persists them.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let store = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            let site = store.addSite(name: " My App ", domain: "MYAPP", rootPath: " /Users/test/my-app ", documentRoot: "")

            assert(site.name == "My App", "should trim site name")
            assert(site.domain == "myapp.test", "should normalize site domain")
            assert(site.rootPath == "/Users/test/my-app", "should trim root path")
            assert(site.documentRoot == ".", "should default empty document root to project root")
            assert(store.persistenceErrors.isEmpty, "should save without persistence errors")

            let savedData = try Data(contentsOf: directory.appendingPathComponent("sites.json"))
            let savedObject = try JSONSerialization.jsonObject(with: savedData) as? [String: Any]
            assert(savedObject?["schemaVersion"] as? Int == StoreSchema.currentVersion, "should write schema version")
            assert(savedObject?["payload"] != nil, "should write payload envelope")

            let reloaded = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            assert(reloaded.sites.count == 1, "should reload saved sites")
            assert(reloaded.sites.first?.domain == "myapp.test", "should persist normalized domain")
        } catch {
            failed += 1
            print("  FAIL: envelope persistence test threw: \(error)")
        }

        // Test: legacy raw arrays are loaded, backed up, and rewritten as envelopes.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let legacySite = Site(name: "Legacy", domain: "legacy.test", rootPath: "/Users/test/legacy")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([legacySite]).write(to: directory.appendingPathComponent("sites.json"))

            let store = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            assert(store.sites.count == 1, "should load legacy site arrays")
            assert(store.persistenceErrors.contains { $0.contains("Migrated legacy sites storage") }, "should report legacy migration")

            let filenames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            assert(filenames.contains { $0.hasPrefix("sites.json.legacy-") }, "should create a legacy backup")

            let migratedData = try Data(contentsOf: directory.appendingPathComponent("sites.json"))
            let migratedObject = try JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
            assert(migratedObject?["schemaVersion"] as? Int == StoreSchema.currentVersion, "should rewrite legacy file as envelope")
        } catch {
            failed += 1
            print("  FAIL: legacy migration persistence test threw: \(error)")
        }

        // A failed rename must not change memory or the independently writable tunnel file.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            let original = store.addSite(name: "Original", domain: "old.test", rootPath: directory.path, documentRoot: ".")
            store.addTunnelRoute(TunnelRoute(kind: .php, subdomain: "public", publicDomain: "example.com",
                localDomain: original.domain, originPort: 443, linkedSiteDomain: original.domain))
            let tunnelsFile = directory.appendingPathComponent("tunnels.json")
            let originalTunnels = try Data(contentsOf: tunnelsFile)
            let sitesFile = directory.appendingPathComponent("sites.json")
            let savedFile = directory.appendingPathComponent("sites.saved")
            try FileManager.default.moveItem(at: sitesFile, to: savedFile)
            try FileManager.default.createDirectory(at: sitesFile, withIntermediateDirectories: true)
            var renamed = original
            renamed.domain = "new.test"
            assert(!store.updateSite(renamed), "rename reports the failed site write")
            assert(store.sites == [original], "failed rename preserves the original in-memory site")
            assert(try Data(contentsOf: tunnelsFile) == originalTunnels, "failed rename does not write linked tunnels")
            assert(store.caddyConfigurationError != nil && store.tunnelConfigurationError != nil, "save failure blocks applying either configuration")
            try FileManager.default.removeItem(at: sitesFile)
            try FileManager.default.moveItem(at: savedFile, to: sitesFile)
            let reopened = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            assert(reopened.sites.first?.domain == "old.test" && reopened.tunnelRoutes.first?.linkedSiteDomain == "old.test",
                   "reopening after failure keeps the site and tunnel linked to the same domain")
            assert(store.updateSite(renamed), "rename can be retried after the write problem is repaired")
            assert(store.saveError(.sites) == nil && store.tunnelRoutes.first?.localDomain == "new.test", "successful retry clears the error and retargets tunnels")
            let retried = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            assert(retried.sites.first?.domain == "new.test" && retried.tunnelRoutes.first?.linkedSiteDomain == "new.test",
                   "successful rename persists both sides of the link")
        } catch {
            failed += 1
            print("  FAIL: failed rename persistence test threw: \(error)")
        }

        func fail(_ label: String, _ error: Error) {
            failed += 1
            print("  FAIL: \(label) threw: \(error)")
        }

        func envelope(_ payload: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": StoreSchema.currentVersion, "savedAt": "2026-09-30T10:00:00Z", "payload": payload])
        }

        func siteJSON(id: String, createdAt: String = "2026-09-30T10:00:00Z", status: String = "stopped") -> [String: Any] {
            ["id": id, "name": id, "domain": "\(id).test", "rootPath": "/Users/test/\(id)", "documentRoot": ".",
             "status": status, "createdAt": createdAt, "updatedAt": "2026-09-30T10:00:00Z"]
        }

        // The one-time Mind import never runs while the Keychain token is unknown (it could never
        // record completion), runs once otherwise, and only fills empty Cloudflare fields.
        do {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let mind = root.appendingPathComponent("mind")
            let mindData = mind.appendingPathComponent("data")
            try FileManager.default.createDirectory(at: mindData, withIntermediateDirectories: true)
            try Data(#"[{"name": "Mind App", "hostname": "mindapp.example.com", "directory": "/tmp/mind-app", "port": 3100}]"#.utf8)
                .write(to: mindData.appendingPathComponent("projects.json"))
            func writeMindCloudflare(token: String) throws {
                try Data(#"{"apiToken": "\#(token)", "zoneId": "mind-zone", "accountId": "mind-account", "tunnelId": "mind-tunnel", "tunnelDomain": "mind-tunnel.cfargotunnel.com"}"#.utf8)
                    .write(to: mindData.appendingPathComponent("cloudflare.json"))
            }
            let nestSettings = AppSettings(
                cloudflareSettings: CloudflareSettings(accountId: "nest-account", configPath: root.appendingPathComponent("missing.yml").path),
                mindProjectDirectory: mind.path
            )
            let data = root.appendingPathComponent("data")

            try writeMindCloudflare(token: "mind-token")
            let deniedCredentials = DeniedReads()
            let denied = SiteStore(dataDirectory: data, defaults: nestSettings, credentialStore: deniedCredentials)
            assert(denied.credentialError != nil, "Mind migration: fixture reproduces a Keychain read failure")
            assert(denied.appProjects.isEmpty && !denied.settings.hasCompletedMindMigration, "Mind migration is skipped while the token is unknown")
            assert(deniedCredentials.saved.isEmpty, "Mind's token never replaces a Keychain token that could not be read")

            try writeMindCloudflare(token: "")

            let credentials = MemoryCredentialStore(token: "nest-token")
            let migrated = SiteStore(dataDirectory: data, defaults: nestSettings, credentialStore: credentials)
            assert(migrated.appProjects.map(\.hostname) == ["mindapp.example.com"], "Mind migration imports projects once the token is known")
            let cloudflare = migrated.settings.cloudflareSettings
            assert(cloudflare.zoneId == "mind-zone" && cloudflare.tunnelId == "mind-tunnel", "Mind migration fills empty Cloudflare fields")
            assert(cloudflare.accountId == "nest-account", "Mind migration keeps Cloudflare values already set in Nest")
            assert(cloudflare.apiToken == "nest-token" && (try? credentials.load()) == "nest-token", "an empty Mind token never clears the stored token")

            var edited = migrated.appProjects[0]
            edited.port = 4000
            assert(migrated.updateProject(edited), "Mind migration: imported project can be edited")
            let reopened = SiteStore(dataDirectory: data, defaults: nestSettings, credentialStore: credentials)
            assert(reopened.settings.hasCompletedMindMigration && reopened.appProjects.first?.port == 4000,
                   "a completed Mind migration does not re-run over later edits")
        } catch { fail("Mind migration", error) }

        // Legacy imports skip sites Caddy cannot serve, and an invalid or conflicting site cannot be switched on.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            let export = [
                LegacySiteEntry(name: "Good", domain: "good", rootPath: "/Users/test/good", documentRoot: "."),
                LegacySiteEntry(name: "Relative", domain: "relative", rootPath: "relative/path", documentRoot: "."),
                LegacySiteEntry(name: "Escape", domain: "escape", rootPath: "/Users/test/escape", documentRoot: "../public"),
            ]
            let (imported, errors) = try store.importLegacySites(from: JSONEncoder().encode(export))
            assert(imported.map(\.domain) == ["good.test"] && store.sites.map(\.domain) == ["good.test"], "legacy import keeps only valid sites")
            assert(errors.count == 2 && errors.allSatisfy { if case .invalidSite = $0 { return true } else { return false } },
                   "legacy import reports each invalid site")
            assert(errors.first?.localizedDescription.contains("absolute path") == true, "invalid site error explains the problem")

            let invalid = store.addSite(name: "Bad", domain: "bad", rootPath: "relative/bad", documentRoot: ".")
            assert(!store.setSiteStatus(id: invalid.id, status: .running), "an invalid site cannot be switched on")
            assert(store.sites.first { $0.id == invalid.id }?.status == .stopped, "a refused switch leaves the site stopped")
            assert(SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
                .sites.first { $0.id == invalid.id }?.status == .stopped, "a refused switch is not saved as running")

            let good = store.sites[0]
            assert(store.setSiteStatus(id: good.id, status: .running), "a valid site can be switched on")
            let twin = store.addSite(name: "Twin", domain: "good", rootPath: "/Users/test/twin", documentRoot: ".")
            assert(!store.setSiteStatus(id: twin.id, status: .running), "a second running site on one domain is refused")
            assert(store.setSiteStatus(id: good.id, status: .stopped) && store.setSiteStatus(id: twin.id, status: .running),
                   "the domain can move to another site once the first is stopped")
        } catch { fail("site validation", error) }

        // Importing a file that is not a Cloudflare export never blanks the tunnel configuration.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            _ = store.addSite(name: "App", domain: "app", rootPath: "/Users/test/app", documentRoot: ".")
            let configured = CloudflareSettings(tunnelId: "id", tunnelName: "keep", configPath: "/tmp/keep.yml", credentialsFilePath: "/tmp/keep.json")
            assert(store.replaceCloudflareSettings(configured), "Cloudflare import: fixture settings save")
            let settingsFile = directory.appendingPathComponent("settings.json")
            let savedSettings = try Data(contentsOf: settingsFile)
            for (label, data) in [("Sites export", try store.exportSites()), ("empty object", Data("{}".utf8))] {
                do {
                    try store.importCloudflareSettings(from: data)
                    assert(false, "importing a \(label) should be rejected")
                } catch {
                    assert(error.localizedDescription.contains("not a Cloudflare settings export"), "\(label) import explains the rejection")
                }
            }
            assert(store.settings.cloudflareSettings == configured, "rejected import keeps the Cloudflare settings")
            assert(try Data(contentsOf: settingsFile) == savedSettings, "rejected import does not save settings")
            try store.importCloudflareSettings(from: store.exportCloudflareSettings())
            assert(store.settings.cloudflareSettings == configured, "a real export still imports")
        } catch { fail("Cloudflare import validation", error) }

        // Failed saves leave every list and the settings exactly as they are on disk.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let credentials = MemoryCredentialStore(token: "old-token")
            let store = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false, credentialStore: credentials)
            let site = store.addSite(name: "App", domain: "app", rootPath: directory.path, documentRoot: ".")
            let project = store.addProject(name: "API", hostname: "api.example.com", directory: "/tmp/api", port: 3000, command: "")
            assert(store.addTunnelRoute(TunnelRoute(id: "route", kind: .app, subdomain: "api", publicDomain: "example.com", localDomain: "api.example.com", originPort: 3000)),
                   "save-first: fixture route saves")
            let cloudflare = CloudflareSettings(apiToken: "old-token", tunnelName: "tunnel", configPath: "/tmp/tunnel.yml")
            assert(store.replaceCloudflareSettings(cloudflare), "save-first: fixture settings save")
            let sites = store.sites, projects = store.appProjects, routes = store.tunnelRoutes, settings = store.settings
            for file in StoreFile.allCases {
                let url = directory.appendingPathComponent(file.fileName)
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }

            assert(!store.deleteSite(id: site.id) && store.sites == sites, "failed site delete keeps the site")
            assert(!store.setSiteStatus(id: site.id, status: .running) && store.sites == sites, "failed status change keeps the old status")
            _ = store.addSite(name: "New", domain: "new", rootPath: "/Users/test/new", documentRoot: ".")
            assert(store.sites == sites, "failed site add is not listed")
            assert(!store.deleteProject(id: project.id) && store.appProjects == projects, "failed project delete keeps the project")
            assert(!store.addTunnelRoute(TunnelRoute(kind: .app, subdomain: "new", publicDomain: "example.com", localDomain: "new.example.com", originPort: 3001)),
                   "failed route add reports the failure")
            var moved = routes[0]
            moved.originPort = 4000
            assert(!store.updateTunnelRoute(moved), "failed route update reports the failure")
            assert(!store.deleteTunnelRoute(id: routes[0].id), "failed route delete reports the failure")
            assert(!store.replaceTunnelRoutes([]), "failed route replace reports the failure")
            assert(store.tunnelRoutes == routes, "failed route changes keep the stored routes")
            var replacement = cloudflare
            replacement.apiToken = "new-token"
            replacement.tunnelName = "changed"
            assert(!store.replaceCloudflareSettings(replacement), "failed Cloudflare save reports the failure")
            assert(store.settings == settings, "failed Cloudflare save keeps the published settings")
            assert((try? credentials.load()) == "old-token", "failed Cloudflare save puts the previous token back")
            do {
                try store.importCloudflareSettings(from: JSONEncoder().encode(replacement))
                assert(false, "failed Cloudflare import should throw")
            } catch {
                assert(store.settings == settings, "failed Cloudflare import keeps the published settings")
            }
            assert(store.saveError(.sites) != nil && store.saveError(.settings) != nil, "failed saves are reported")
        } catch { fail("save-first mutations", error) }

        // Stored dates load with and without fractional seconds.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try envelope([siteJSON(id: "plain"), siteJSON(id: "fraction", createdAt: "2026-09-30T10:00:00.250Z")])
                .write(to: directory.appendingPathComponent("sites.json"))
            let loaded = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            assert(loaded.sites.map(\.id) == ["plain", "fraction"], "should decode plain and fractional ISO 8601 dates")
            if loaded.sites.count == 2 {
                let delta = loaded.sites[1].createdAt.timeIntervalSince(loaded.sites[0].createdAt)
                assert(abs(delta - 0.25) < 0.001, "should keep fractional seconds")
            }
        } catch { fail("date decoding", error) }

        // A file that keeps a skipped record is backed up once per distinct content, not per launch.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sitesURL = directory.appendingPathComponent("sites.json")
            try envelope([siteJSON(id: "a"), siteJSON(id: "b", status: "paused")]).write(to: sitesURL)
            func backups() throws -> [String] {
                try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("sites.json.invalid-") }
            }
            _ = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            assert(try backups().count == 1, "first launch backs up the partially readable file")
            // Simulate a backup taken at an earlier launch (backup names have one-second resolution).
            let first = try backups()[0]
            try FileManager.default.moveItem(at: directory.appendingPathComponent(first),
                                             to: directory.appendingPathComponent("sites.json.invalid-2000-01-01T00-00-00Z"))
            let relaunched = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            assert(try backups().count == 1, "a later launch reuses the backup of identical content")
            assert(relaunched.persistenceErrors.contains { $0.contains("already exists") }, "a reused backup is still reported")
            try envelope([siteJSON(id: "a"), siteJSON(id: "c"), siteJSON(id: "b", status: "paused")]).write(to: sitesURL)
            _ = SiteStore(dataDirectory: directory, defaults: AppSettings(), runOneTimeMigrations: false)
            assert(try backups().count == 2, "changed content gets its own backup")
        } catch { fail("backup deduplication", error) }

        // Optional runtime paths (and php.ini, which launches FrankenPHP) are detected once, not every launch.
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let marker = directory.appendingPathComponent("frankenphp-runs")
            let frankenphp = directory.appendingPathComponent("frankenphp")
            try "#!/bin/sh\necho run >> '\(marker.path)'\necho /nonexistent/php.ini\n".write(to: frankenphp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: frankenphp.path)
            func runs() -> Int {
                ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").count
            }
            let paths = RuntimePaths(frankenphpBinary: frankenphp.path, mariadbServer: "/x/mariadbd", mariadbClient: "/x/mariadb",
                                     mysqldump: "/x/mariadb-dump", cloudflaredBinary: "/x/cloudflared", frankenphpLog: "/x/f.log",
                                     mariadbLog: "/x/m.err", cloudflaredLog: "/x/c.log", phpIniPath: "")
            let data = directory.appendingPathComponent("data")
            _ = SiteStore(dataDirectory: data, defaults: AppSettings(runtimePaths: paths), runOneTimeMigrations: false)
            assert(FileManager.default.fileExists(atPath: data.appendingPathComponent("settings.json").path), "first-launch defaults are saved")
            let detected = SiteStore(dataDirectory: data, defaults: AppSettings(), runOneTimeMigrations: false)
            assert(runs() == 1 && detected.settings.hasDetectedRuntimePaths, "missing optional paths are detected on the next launch")
            let relaunched = SiteStore(dataDirectory: data, defaults: AppSettings(), runOneTimeMigrations: false)
            assert(runs() == 1, "detection does not launch FrankenPHP again on later launches")
            assert(relaunched.settings.runtimePaths == paths, "paths that stayed undetected remain empty")
        } catch { fail("runtime path detection", error) }

        return (passed, failed)
    }

    private static func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nest-store-\(UUID().uuidString)", isDirectory: true)
    }

    /// A Keychain whose reads are denied, as when the user refuses access.
    private final class DeniedReads: CredentialStore {
        var saved: [String] = []
        func load() throws -> String { throw ConfigurationFailure("Keychain read denied") }
        func save(_ token: String) throws { saved.append(token) }
    }
}
