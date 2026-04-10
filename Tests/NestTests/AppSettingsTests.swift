import Foundation
import Darwin
import NestLib

enum AppSettingsTests {
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

        func withBundleIdentifier(_ bundleIdentifier: String, _ block: () -> Void) {
            let key = "NEST_BUNDLE_ID"
            let original = ProcessInfo.processInfo.environment[key]
            setenv(key, bundleIdentifier, 1)
            block()
            if let original {
                setenv(key, original, 1)
            } else {
                unsetenv(key)
            }
        }

        withBundleIdentifier(AppSettings.developmentBundleIdentifier) {
            assert(AppSettings.currentBundleIdentifier == AppSettings.developmentBundleIdentifier, "should resolve development bundle identifier")
            assert(AppSettings.nestDataDirectory.hasSuffix("/\(AppSettings.developmentBundleIdentifier)/config"), "development data directory should be variant-specific")
            assert(AppSettings.nestLogsDirectory.hasSuffix("/\(AppSettings.developmentBundleIdentifier)/logs"), "development logs directory should be variant-specific")
        }

        withBundleIdentifier(AppSettings.productionBundleIdentifier) {
            assert(AppSettings.currentBundleIdentifier == AppSettings.productionBundleIdentifier, "should resolve production bundle identifier")
            assert(AppSettings.nestDataDirectory.hasSuffix("/\(AppSettings.productionBundleIdentifier)/config"), "production data directory should be variant-specific")
            assert(AppSettings.nestRunDirectory.hasSuffix("/\(AppSettings.productionBundleIdentifier)/run"), "production run directory should be variant-specific")
        }

        return (passed, failed)
    }
}
