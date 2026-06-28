import Foundation
import NestLib

@main
struct TestRunner {
    @MainActor
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
        run("AppSettings", AppSettingsTests.runAll)
        run("RuntimePaths", RuntimePathsTests.runAll)
        run("Validation", ValidationTests.runAll)
        run("PrerequisiteChecker", PrerequisiteCheckerTests.runAll)
        run("ProjectCommandResolver", ProjectCommandResolverTests.runAll)
        run("ProjectLaunchPlanner", ProjectLaunchPlannerTests.runAll)
        run("PFRestorePlanner", PFRestorePlannerTests.runAll)
        run("ParkedFolderScanner", ParkedFolderScannerTests.runAll)
        run("ConfigRenderer", ConfigRendererTests.runAll)
        run("SiteStorePersistence", SiteStorePersistenceTests.runAll)
        run("LogTailReader", LogTailReaderTests.runAll)
        run("TunnelConfigRenderer", TunnelConfigRendererTests.runAll)
        run("MindImportService", MindImportServiceTests.runAll)
        run("MigrationService", MigrationServiceTests.runAll)

        print("Total: \(totalPassed) passed, \(totalFailed) failed")

        if totalFailed > 0 {
            exit(1)
        }
    }
}
