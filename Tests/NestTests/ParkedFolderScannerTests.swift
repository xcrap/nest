import Foundation
import NestLib

enum ParkedFolderScannerTests {
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

        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let app = directory.appendingPathComponent("My Laravel App", isDirectory: true)
            let publicDir = app.appendingPathComponent("public", isDirectory: true)
            try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
            try Data("<?php".utf8).write(to: app.appendingPathComponent("artisan"))

            let scan = ParkedFolderScanner.scan(directory: directory)
            assert(scan.candidates.count == 1, "should discover project child folders")
            assert(scan.candidates.first?.name == "My Laravel App", "should infer display name")
            assert(scan.candidates.first?.domain == "my-laravel-app.test", "should infer .test domain")
            assert(scan.candidates.first?.documentRoot == "public", "should infer public document root")
        } catch {
            failed += 1
            print("  FAIL: parked folder scan test threw: \(error)")
        }

        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let app = directory.appendingPathComponent("Existing", isDirectory: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("web", isDirectory: true), withIntermediateDirectories: true)

            let scan = ParkedFolderScanner.scan(directory: directory, existingDomains: ["existing.test"])
            assert(scan.candidates.isEmpty, "should skip existing domains")
            assert(scan.skippedExisting == ["existing.test"], "should report skipped existing domains")
        } catch {
            failed += 1
            print("  FAIL: parked folder duplicate test threw: \(error)")
        }

        return (passed, failed)
    }

    private static func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nest-parked-\(UUID().uuidString)", isDirectory: true)
    }
}
