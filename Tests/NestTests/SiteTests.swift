import Foundation
import NestLib

enum SiteTests {
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

        // Test: resolvedDocumentRoot with public
        do {
            let site = Site(name: "Test", domain: "test.test", rootPath: "/var/www/test", documentRoot: "public")
            assert(site.resolvedDocumentRoot == "/var/www/test/public", "public doc root")
        }

        // Test: resolvedDocumentRoot with dot
        do {
            let site = Site(name: "Test", domain: "test.test", rootPath: "/var/www/test", documentRoot: ".")
            assert(site.resolvedDocumentRoot == "/var/www/test", "dot doc root")
        }

        // Test: resolvedDocumentRoot with web
        do {
            let site = Site(name: "Test", domain: "test.test", rootPath: "/var/www/test", documentRoot: "web")
            assert(site.resolvedDocumentRoot == "/var/www/test/web", "web doc root")
        }

        // Test: inferDocumentRoot with no public dir
        do {
            let tmpDir = NSTemporaryDirectory() + "nest-test-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let result = Site.inferDocumentRoot(rootPath: tmpDir, specified: nil)
            assert(result == ".", "infer dot when no public dir")
        }

        // Test: inferDocumentRoot detects public directory
        do {
            let tmpDir = NSTemporaryDirectory() + "nest-test-\(UUID().uuidString)"
            let publicDir = (tmpDir as NSString).appendingPathComponent("public")
            try? FileManager.default.createDirectory(atPath: publicDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let result = Site.inferDocumentRoot(rootPath: tmpDir, specified: nil)
            assert(result == "public", "infer public when dir exists")
        }

        // Test: inferDocumentRoot uses specified value
        do {
            let result = Site.inferDocumentRoot(rootPath: "/var/www", specified: "web")
            assert(result == "web", "use specified doc root")
        }

        return (passed, failed)
    }
}
