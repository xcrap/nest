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

        // Test: only a trailing .test is removed when editing a site domain.
        do {
            assert(NestValidation.siteDomainLabel("api.testapp.test") == "api.testapp", "should keep inner .test labels")
            assert(NestValidation.siteDomainLabel("api.testing.test") == "api.testing", "should keep labels starting with test")
            assert(NestValidation.siteDomainLabel("plain") == "plain", "should leave domains without .test alone")
        }

        // Test: Caddy keeps backslashes literally and expands braces, so neither may reach a path.
        do {
            assert(NestValidation.caddyfileArgument("/x/back\\slash") == "\"/x/back\\slash\"", "should not double backslashes for Caddy")
            assert(NestValidation.caddyfileArgument("/x/say \"hi\"") == "\"/x/say \\\"hi\\\"\"", "should escape quotes for Caddy")
            let braced = Site(name: "App", domain: "app.test", rootPath: "/Users/test/{$HOME}", documentRoot: ".")
            assert(NestValidation.siteIssues(braced).contains { $0.contains("{, }") }, "should reject Caddy placeholders in site paths")
            let slashed = Site(name: "App", domain: "app.test", rootPath: "/Users/test/back\\slash", documentRoot: ".")
            assert(!NestValidation.siteIssues(slashed).isEmpty, "should reject backslashes in site paths")
        }

        // Test: YAML plain scalars never change type or meaning.
        do {
            assert(NestValidation.yamlScalar("app.example.com") == "app.example.com", "should keep hostnames plain")
            assert(NestValidation.yamlScalar("https://localhost:443") == "https://localhost:443", "should keep service URLs plain")
            assert(NestValidation.yamlScalar("~") == "\"~\"", "should quote the YAML null shorthand")
            assert(NestValidation.yamlScalar("@tunnel") == "\"@tunnel\"", "should quote reserved leading indicators")
            assert(NestValidation.yamlScalar("tunnel:") == "\"tunnel:\"", "should quote trailing colons")
            assert(NestValidation.yamlScalar("12345") == "\"12345\"", "should quote numbers")
            assert(NestValidation.yamlScalar("yes") == "\"yes\"", "should quote YAML booleans")
        }

        return (passed, failed)
    }
}
