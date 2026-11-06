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

        // Without the helper, the administrator prompt is shown only when it can help.
        assert(PFRestorePlanner.reloadMethod(helperEnabled: true, pfConfLoadsAnchor: false, promptAllowed: false) == .helper,
               "the enabled helper repairs without a prompt")
        assert(PFRestorePlanner.reloadMethod(helperEnabled: false, pfConfLoadsAnchor: true, promptAllowed: true) == .administratorPrompt,
               "a wired pf.conf is reloaded behind the administrator prompt")
        assert(PFRestorePlanner.reloadMethod(helperEnabled: false, pfConfLoadsAnchor: false, promptAllowed: true) == .unavailable(.notWired),
               "no prompt when pf.conf lacks Nest's anchor: a reload cannot fix it")
        assert(PFRestorePlanner.reloadMethod(helperEnabled: false, pfConfLoadsAnchor: true, promptAllowed: false) == .unavailable(.suppressed),
               "no prompt again after the user declined it")

        let stock = """
        scrub-anchor "com.apple/*"
        nat-anchor "com.apple/*"
        rdr-anchor "com.apple/*"
        dummynet-anchor "com.apple/*"
        anchor "com.apple/*"
        load anchor "com.apple" from "/etc/pf.anchors/com.apple"

        """
        let helperWired = stock.replacingOccurrences(of: "rdr-anchor \"com.apple/*\"",
            with: "# BEGIN NEST PF ANCHOR\nrdr-anchor \"app.nest\"\nload anchor \"app.nest\" from \"/etc/pf.anchors/app.nest\"\n# END NEST PF ANCHOR\nrdr-anchor \"com.apple/*\"")
        let manualWired = stock + "rdr-anchor \"dev.nest.app\"\nload anchor \"dev.nest.app\" from \"/etc/pf.anchors/dev.nest.app\"\n"
        let commented = stock + "# rdr-anchor \"dev.nest.app\"\n# load anchor \"dev.nest.app\" from \"/etc/pf.anchors/dev.nest.app\"\n"
        let everyAnchor: (String) -> Bool = { _ in true }
        assert(!PFRestorePlanner.pfConfLoadsNestAnchor(stock, anchorExists: everyAnchor), "the stock pf.conf does not load Nest's anchor")
        assert(PFRestorePlanner.pfConfLoadsNestAnchor(helperWired, anchorExists: everyAnchor), "the helper's managed block counts as wiring")
        assert(PFRestorePlanner.pfConfLoadsNestAnchor(manualWired, anchorExists: everyAnchor), "the manual development anchor counts as wiring")
        assert(!PFRestorePlanner.pfConfLoadsNestAnchor(commented, anchorExists: everyAnchor), "commented-out lines are not wiring")
        assert(!PFRestorePlanner.pfConfLoadsNestAnchor(helperWired, anchorExists: { _ in false }), "a missing anchor file cannot be loaded")
        assert(!PFRestorePlanner.pfConfLoadsNestAnchor(stock + "rdr-anchor \"app.nest\"\n", anchorExists: everyAnchor), "a declaration without its load line is not wiring")

        assert(PFRestorePlanner.promptOutcome(status: 1, output: "execution error: User canceled. (-128)", redirectWorking: false) == .declined,
               "a cancelled prompt is recognized")
        assert(PFRestorePlanner.promptOutcome(status: 0, output: "", redirectWorking: true) == .repaired, "a working reload repairs the redirect")
        assert(PFRestorePlanner.promptOutcome(status: 0, output: "", redirectWorking: false) == .ineffective,
               "a reload that leaves the ports elsewhere is reported")
        assert(PFRestorePlanner.promptOutcome(status: 1, output: "pfctl: Syntax error\n", redirectWorking: false) == .failed("pfctl: Syntax error"),
               "other failures keep their output")
        assert([PortRedirectRepairOutcome.declined, .ineffective, .failed("x")].allSatisfy(\.suppressesPrompt)
               && ![PortRedirectRepairOutcome.notWired, .helperFailed, .repaired, .notNeeded, .suppressed].contains(where: \.suppressesPrompt),
               "only outcomes a repeated prompt cannot fix suppress it")
        assert(PortRedirectRepairOutcome.notWired.message?.contains("pf.conf") == true && PortRedirectRepairOutcome.repaired.message == nil,
               "failures carry a message, success does not")

        return (passed, failed)
    }
}
