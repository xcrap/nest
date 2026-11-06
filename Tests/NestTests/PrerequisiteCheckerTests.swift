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

        // Test: dnsmasq conf-dir extensions follow dnsmasq's include/exclude rules.
        do {
            assert(!PrerequisiteChecker.confDirIncludes("old.bak", extensions: [".bak"]), "plain extension excludes matching files")
            assert(PrerequisiteChecker.confDirIncludes("valet.conf", extensions: [".bak"]), "plain extension keeps other files")
            assert(PrerequisiteChecker.confDirIncludes("valet.conf", extensions: ["*.conf"]), "*.ext includes matching files")
            assert(!PrerequisiteChecker.confDirIncludes("old.bak", extensions: ["*.conf"]), "*.ext reads only matching files")
            assert(!PrerequisiteChecker.confDirIncludes("x.conf.bak", extensions: ["*.conf", ".bak"]), "exclusions apply alongside inclusions")
            assert(PrerequisiteChecker.confDirIncludes("notes", extensions: []), "no extensions reads every file")
            assert(!PrerequisiteChecker.confDirIncludes(".hidden", extensions: []), "dot files are always skipped")
            assert(!PrerequisiteChecker.confDirIncludes("edit.conf~", extensions: []), "backup files are always skipped")
            assert(!PrerequisiteChecker.confDirIncludes("#draft#", extensions: []), "#name# files are always skipped")

            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nest-confdir-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "address=/test/127.0.0.1\n".write(to: directory.appendingPathComponent("old.bak"), atomically: true, encoding: .utf8)
            try "port=5354\n".write(to: directory.appendingPathComponent("nest.conf"), atomically: true, encoding: .utf8)
            let names = { (line: String) in PrerequisiteChecker.defaultIncludedFiles(line).map { ($0 as NSString).lastPathComponent } }
            assert(names("conf-dir=\(directory.path),.bak") == ["nest.conf"], "conf-dir=dir,.bak excludes .bak files")
            assert(names("conf-dir=\(directory.path),*.conf") == ["nest.conf"], "conf-dir=dir,*.conf includes only .conf files")
            assert(names("conf-dir=\(directory.path)") == ["nest.conf", "old.bak"], "conf-dir=dir reads every file")
            let excluded = PrerequisiteChecker.parseDnsmasqConfiguration("conf-dir=\(directory.path),.bak\n")
            assert(excluded == .init(port: 5354, resolvesTestDomains: false), "an excluded file's address does not count")
        } catch {
            assert(false, "conf-dir fixtures: \(error)")
        }

        // Test: address= lines are parsed, not matched literally.
        do {
            for value in ["/test/127.0.0.1", "/.test/127.0.0.1", " /localhost/test/127.0.0.1", "/#/127.0.0.1", "/TEST/127.0.0.1"] {
                assert(PrerequisiteChecker.addressResolvesTestDomains(value), "should accept address=\(value)")
            }
            for value in ["/test/10.0.0.1", "/testing/127.0.0.1", "/.test/::1", "127.0.0.1", "/test/"] {
                assert(!PrerequisiteChecker.addressResolvesTestDomains(value), "should reject address=\(value)")
            }
            let parsed = PrerequisiteChecker.parseDnsmasqConfiguration("address = /dev/test/127.0.0.1\n", includedFiles: { _ in [] })
            assert(parsed.resolvesTestDomains, "should accept multi-domain address lines with spacing")
        }

        // Test: the live dnsmasq query only passes on a loopback answer.
        do {
            assert(PrerequisiteChecker.digAnswerIsLoopback("127.0.0.1\n"), "loopback answer passes")
            assert(PrerequisiteChecker.digAnswerIsLoopback("alias.test.\n127.0.0.1\n"), "loopback after a CNAME passes")
            assert(!PrerequisiteChecker.digAnswerIsLoopback(""), "no answer fails")
            assert(!PrerequisiteChecker.digAnswerIsLoopback(";; connection timed out; no servers could be reached\n"), "timeout fails")
            assert(!PrerequisiteChecker.digAnswerIsLoopback("10.0.0.1\n"), "another address fails")
            assert(PrerequisiteChecker.queryDnsmasqForTestDomain(port: 5354, digPath: "/nonexistent/dig") == nil,
                   "missing dig falls back to the process check")
        }

        // Test: nestctl doctor exits 1 only when it prints an error.
        do {
            func result(_ passed: Bool, _ severity: PrerequisiteChecker.CheckSeverity? = nil) -> PrerequisiteChecker.CheckResult {
                .init(id: .dnsmasq, category: .dns, name: "x", passed: passed, severity: severity, detail: "", fixHint: "")
            }
            assert(PrerequisiteChecker.doctorExitStatus(runtimeIssues: [], checks: [result(true), result(true)]) == 0, "all passing exits 0")
            assert(PrerequisiteChecker.doctorExitStatus(runtimeIssues: [], checks: [result(false, .warning)]) == 0, "warnings exit 0")
            assert(PrerequisiteChecker.doctorExitStatus(runtimeIssues: [], checks: [result(true), result(false)]) == 1, "a failed check exits 1")
            assert(PrerequisiteChecker.doctorExitStatus(runtimeIssues: ["FrankenPHP binary path is not set."], checks: []) == 1,
                   "runtime path errors exit 1")
        }

        // Test: the helper status can come from outside SMAppService (nestctl has no app bundle).
        do {
            let previous = AppSettings.bundleIdentifierOverride
            AppSettings.bundleIdentifierOverride = AppSettings.productionBundleIdentifier
            defer { AppSettings.bundleIdentifierOverride = previous }
            if PFHelperManager.isSupported {
                assert(PFHelperManager.statusFromSystem(launchdKnowsService: { true }, anchorInstalled: { false }, redirectWorking: { false }) == .enabled,
                       "a loaded launchd job is enabled")
                assert(PFHelperManager.statusFromSystem(launchdKnowsService: { false }, anchorInstalled: { true }, redirectWorking: { true }) == .enabled,
                       "the helper's anchor with a live redirect is enabled")
                assert(PFHelperManager.statusFromSystem(launchdKnowsService: { false }, anchorInstalled: { true }, redirectWorking: { false }) == .notRegistered,
                       "a stale anchor alone is not enabled")
                assert(PFHelperManager.statusFromSystem(launchdKnowsService: { false }, anchorInstalled: { false }, redirectWorking: { true }) == .notRegistered,
                       "another redirect without the helper's anchor is not the helper")
                let approval = PrerequisiteChecker.checkPFAnchor(helperStatus: .requiresApproval)
                assert(!approval.passed && approval.action == .openPFHelperSettings, "checker uses the supplied helper status")
                let missing = PrerequisiteChecker.checkPFAnchor(helperStatus: .notFound)
                assert(missing.action == .installPFHelper, "a missing helper offers installation")
            }
        }

        return (passed, failed)
    }
}
