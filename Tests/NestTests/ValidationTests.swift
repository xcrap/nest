import Foundation
import NestLib

enum ValidationTests {
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

        // Test: accepts normal Nest site config.
        do {
            let site = Site(name: "App", domain: "app.test", rootPath: "/Users/test/app", documentRoot: "public")
            assert(NestValidation.siteIssues(site).isEmpty, "should accept valid site config")
        }

        // Test: rejects invalid DNS/path input.
        do {
            let site = Site(name: "", domain: "bad domain.test", rootPath: "relative/path", documentRoot: "../public")
            let issues = NestValidation.siteIssues(site)
            assert(issues.contains { $0.contains("Site name") }, "should require a site name")
            assert(issues.contains { $0.contains("invalid DNS label") }, "should reject invalid DNS labels")
            assert(issues.contains { $0.contains("absolute path") }, "should require absolute root paths")
            assert(issues.contains { $0.contains("inside the site root") }, "should reject document root traversal")
        }

        // Test: normalizes user-entered domains.
        do {
            assert(NestValidation.normalizedDomain(" MyApp ", defaultTLD: "test") == "myapp.test", "should append default .test domain")
            assert(NestValidation.normalizedDomain("MyApp.TEST.", defaultTLD: "test") == "myapp.test", "should lowercase and remove trailing dot")
        }

        // Test: quotes renderer scalars safely.
        do {
            assert(NestValidation.caddyfileArgument("/Users/test/My App") == "\"/Users/test/My App\"", "should quote Caddyfile args")
            assert(NestValidation.yamlScalar("/Users/test/My App/config.yml") == "\"/Users/test/My App/config.yml\"", "should quote YAML scalars with spaces")
        }

        return (passed, failed)
    }
}
