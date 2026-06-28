import Foundation
import NestLib

enum PrerequisiteCheckerTests {
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

        // Test: check results have stable IDs and typed categories.
        do {
            let result = PrerequisiteChecker.CheckResult(
                id: .dnsmasq,
                category: .dns,
                name: "dnsmasq",
                passed: false,
                detail: "missing",
                fixHint: "brew install dnsmasq",
                fixCommands: ["brew install dnsmasq"]
            )

            assert(result.id == .dnsmasq, "should expose stable check ID")
            assert(result.category == .dns, "should expose typed category")
            assert(result.fixCommands == ["brew install dnsmasq"], "should expose typed fix commands")
            assert(result.action == .none, "should default to no action")
        }

        return (passed, failed)
    }
}
