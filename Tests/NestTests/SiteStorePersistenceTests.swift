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

        return (passed, failed)
    }

    private static func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nest-store-\(UUID().uuidString)", isDirectory: true)
    }
}
