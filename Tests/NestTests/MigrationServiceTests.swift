import Foundation
import NestLib

enum MigrationServiceTests {
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

        // Test: parses v1 format
        do {
            let json = """
            {
                "version": 1,
                "exportedAt": "2025-01-01T00:00:00Z",
                "sites": [
                    {"name": "My Site", "domain": "mysite.test", "rootPath": "/var/www/mysite", "documentRoot": "public"}
                ]
            }
            """
            let entries = try MigrationService.parseImportData(json.data(using: .utf8)!)
            assert(entries.count == 1, "v1 should parse 1 site")
            assert(entries[0].name == "My Site", "v1 site name")
            assert(entries[0].domain == "mysite.test", "v1 site domain")
        } catch {
            failed += 1
            print("  FAIL: v1 parse threw: \(error)")
        }

        // Test: parses plain array
        do {
            let json = """
            [
                {"name": "Site A", "domain": "a.test", "rootPath": "/var/www/a"},
                {"name": "Site B", "domain": "b.test", "rootPath": "/var/www/b"}
            ]
            """
            let entries = try MigrationService.parseImportData(json.data(using: .utf8)!)
            assert(entries.count == 2, "array should parse 2 sites")
        } catch {
            failed += 1
            print("  FAIL: array parse threw: \(error)")
        }

        // Test: rejects invalid format
        do {
            let json = """
            {"invalid": true}
            """
            _ = try MigrationService.parseImportData(json.data(using: .utf8)!)
            failed += 1
            print("  FAIL: should have thrown for invalid format")
        } catch {
            passed += 1
        }

        // Test: validates missing domain
        do {
            let entries = [LegacySiteEntry(name: "No Domain", domain: "", rootPath: "/var/www")]
            let errors = MigrationService.validateEntries(entries, existingDomains: [])
            assert(errors.count == 1, "missing domain should produce 1 error")
            assert(errors[0] == .missingDomain(siteName: "No Domain"), "missing domain error type")
        }

        // Test: validates missing root path
        do {
            let entries = [LegacySiteEntry(name: "No Path", domain: "nopath.test", rootPath: "")]
            let errors = MigrationService.validateEntries(entries, existingDomains: [])
            assert(errors.count == 1, "missing root path should produce 1 error")
            assert(errors[0] == .missingRootPath(siteName: "No Path"), "missing root path error type")
        }

        // Test: validates duplicate domain against existing
        do {
            let entries = [LegacySiteEntry(name: "Dup", domain: "existing.test", rootPath: "/var/www")]
            let errors = MigrationService.validateEntries(entries, existingDomains: ["existing.test"])
            assert(errors.count == 1, "duplicate existing should produce 1 error")
            assert(errors[0] == .duplicateDomain(domain: "existing.test"), "duplicate domain error type")
        }

        // Test: validates duplicate within batch
        do {
            let entries = [
                LegacySiteEntry(name: "First", domain: "dup.test", rootPath: "/var/www/a"),
                LegacySiteEntry(name: "Second", domain: "dup.test", rootPath: "/var/www/b"),
            ]
            let errors = MigrationService.validateEntries(entries, existingDomains: [])
            assert(errors.count == 1, "batch duplicate should produce 1 error")
            assert(errors[0] == .duplicateDomain(domain: "dup.test"), "batch duplicate error type")
        }

        return (passed, failed)
    }
}
