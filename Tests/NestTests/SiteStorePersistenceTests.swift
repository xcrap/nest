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

        return (passed, failed)
    }

    private static func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nest-store-\(UUID().uuidString)", isDirectory: true)
    }
}
