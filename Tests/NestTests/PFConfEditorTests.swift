import Foundation
import NestPFCore

/// The root helper's /etc/pf.conf edits, tested on strings only.
enum PFConfEditorTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 } else { failed += 1; print("  FAIL: \(message)") }
        }
        func inserted(_ content: String) -> String? { try? PFConfEditor.insertingManagedBlock(into: content) }
        func removed(_ content: String) -> String? { try? PFConfEditor.removingManagedBlock(from: content) }
        func refused(_ content: String) -> Bool {
            do { _ = try PFConfEditor.insertingManagedBlock(into: content); return false }
            catch { return error is PFConfEditor.UnbalancedMarkers }
        }

        // macOS's stock /etc/pf.conf (comments trimmed).
        let stock = """
        #
        # com.apple anchor point
        #
        scrub-anchor "com.apple/*"
        nat-anchor "com.apple/*"
        rdr-anchor "com.apple/*"
        dummynet-anchor "com.apple/*"
        anchor "com.apple/*"
        load anchor "com.apple" from "/etc/pf.anchors/com.apple"

        """
        let block = [
            "# BEGIN NEST PF ANCHOR",
            "rdr-anchor \"app.nest\"",
            "load anchor \"app.nest\" from \"/etc/pf.anchors/app.nest\"",
            "# END NEST PF ANCHOR",
        ]

        check(PFConfEditor.managedBlock == block.joined(separator: "\n"), "the managed block keeps its exact text")
        check(PFConfEditor.anchorContents == "rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port 8080\nrdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port 8443\n",
              "the anchor rules keep their exact text")

        guard let once = inserted(stock) else { check(false, "inserting into the stock pf.conf succeeds"); return (passed, failed) }
        check(inserted(once) == once, "inserting twice equals inserting once")
        let lines = once.components(separatedBy: "\n")
        if let start = lines.firstIndex(of: block[0]), let apple = lines.firstIndex(of: "rdr-anchor \"com.apple/*\"") {
            check(Array(lines[start..<start + block.count]) == block, "the block is inserted whole")
            check(start + block.count == apple, "the block goes directly before Apple's rdr-anchor")
            check(lines.firstIndex(of: "scrub-anchor \"com.apple/*\"")! < start, "the block stays after scrub-anchor")
        } else {
            check(false, "the block and Apple's rdr-anchor are present")
        }
        check(once.hasSuffix("\n") && !once.hasSuffix("\n\n"), "the trailing newline is preserved")
        check(inserted("pass all") == "pass all\n" + block.joined(separator: "\n"), "a file without anchors gets the block appended")
        check(removed(once) == stock, "removing the block restores the original file")
        check(removed(stock) == stock, "removing from a file without the block changes nothing")

        // Stray Nest lines outside the markers are dropped, then the block is added once.
        let stray = stock.replacingOccurrences(of: "\nanchor \"com.apple/*\"\n", with: "\nanchor \"com.apple/*\"\n\(block[1])\n\(block[2])\n")
        check(stray != stock && removed(stray) == stock, "stray anchor lines are removed")
        check(inserted(stray) == once, "stray anchor lines are replaced by a single managed block")
        let indented = stock + "  \(block[1])  \n"
        check(removed(indented) == stock, "indented stray lines are recognized")

        // Unbalanced or tampered markers are refused instead of guessed at.
        check(refused(stock + block[0] + "\n" + block[1] + "\n"), "a start marker without an end marker is refused")
        check(refused(stock + block[3] + "\n"), "an end marker without a start marker is refused")
        check(refused(stock + block[0] + "\n" + block[0] + "\n" + block[3] + "\n"), "a nested start marker is refused")
        check(refused(stock + block[0] + "\npass in all\n" + block[3] + "\n"), "a foreign rule inside the markers is refused")
        check(PFConfEditor.UnbalancedMarkers().description == "/etc/pf.conf has unbalanced Nest markers; refusing to edit it",
              "the refusal message is unchanged")

        check(PFConfEditor.isEnabled(statusInfo: "Status: Enabled for 0 days 01:02:03           Debug: Urgent\n\nState Table"),
              "an enabled PF is recognized")
        check(!PFConfEditor.isEnabled(statusInfo: "Status: Disabled for 0 days 00:00:00           Debug: Urgent\n"),
              "a disabled PF is recognized")
        check(!PFConfEditor.isEnabled(statusInfo: ""), "unknown status is treated as disabled")
        return (passed, failed)
    }
}
