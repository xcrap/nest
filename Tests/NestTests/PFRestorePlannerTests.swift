import Foundation
import NestLib

enum PFRestorePlannerTests {
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

        assert(
            PFRestorePlanner.decision(frankenphpRunning: false, redirectWorking: false) == .skipFrankenPHPStopped,
            "should skip PF reload when FrankenPHP is stopped"
        )
        assert(
            PFRestorePlanner.decision(frankenphpRunning: true, redirectWorking: true) == .skipRedirectAlreadyWorking,
            "should skip PF reload when redirect already works"
        )
        assert(
            PFRestorePlanner.decision(frankenphpRunning: true, redirectWorking: false) == .reloadPF,
            "should reload PF when FrankenPHP runs but redirect is broken"
        )

        return (passed, failed)
    }
}
