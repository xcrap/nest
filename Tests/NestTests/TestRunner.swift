import Foundation
import NestLib

@main
struct TestRunner {
    static func main() {
        print("Running Nest tests...\n")

        var totalPassed = 0
        var totalFailed = 0

        func run(_ name: String, _ block: () -> (passed: Int, failed: Int)) {
            print("Suite: \(name)")
            let (p, f) = block()
            totalPassed += p
            totalFailed += f
            print("  \(p) passed, \(f) failed\n")
        }

        run("Site Model", SiteTests.runAll)
        run("ConfigRenderer", ConfigRendererTests.runAll)
        run("MigrationService", MigrationServiceTests.runAll)

        print("Total: \(totalPassed) passed, \(totalFailed) failed")

        if totalFailed > 0 {
            exit(1)
        }
    }
}
