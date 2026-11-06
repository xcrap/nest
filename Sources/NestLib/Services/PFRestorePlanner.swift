import Foundation

public enum PFRestoreDecision: Equatable {
    case skipFrankenPHPStopped
    case skipRedirectAlreadyWorking
    case reloadPF
}

/// What an attempt to restore the 80/443 → 8080/8443 redirect achieved.
public enum PortRedirectRepairOutcome: Equatable, Sendable {
    /// FrankenPHP is stopped or the redirect already works.
    case notNeeded
    case repaired
    /// The privileged helper ran, but the redirect still does not reach Caddy.
    case helperFailed
    /// /etc/pf.conf does not load Nest's anchor: reloading it cannot help.
    case notWired
    /// An earlier administrator prompt was declined or could not help; not asked again.
    case suppressed
    case declined
    /// PF reloaded, yet ports 80/443 still do not reach Caddy (another server may own them).
    case ineffective
    case failed(String)

    /// Asking for the password again cannot succeed without the user changing something.
    public var suppressesPrompt: Bool {
        switch self {
        case .declined, .ineffective, .failed: return true
        default: return false
        }
    }

    public var message: String? {
        switch self {
        case .notNeeded, .repaired:
            return nil
        case .suppressed:
            return "Ports 80/443 don't reach FrankenPHP. Restoring PF was cancelled or did not help earlier, so Nest won't ask for an administrator password again this session."
        case .helperFailed:
            return "Ports 80/443 don't reach FrankenPHP and the Nest helper could not restore the redirect. Re-run it from the Port Redirect (PF) check."
        case .notWired:
            return "Ports 80/443 don't reach FrankenPHP: /etc/pf.conf does not load Nest's PF anchor. See the Port Redirect (PF) check."
        case .declined:
            return "Ports 80/443 don't reach FrankenPHP: the administrator prompt was cancelled. Nest won't ask again this session."
        case .ineffective:
            return "PF was reloaded, but ports 80/443 still don't reach FrankenPHP. Another local server may be using them."
        case .failed(let output):
            return "Could not reload PF to restore ports 80/443: \(output)"
        }
    }
}

public enum PFReloadMethod: Equatable, Sendable {
    case helper
    case administratorPrompt
    case unavailable(PortRedirectRepairOutcome)
}

public enum PFRestorePlanner {
    public static func decision(frankenphpRunning: Bool, redirectWorking: Bool) -> PFRestoreDecision {
        guard frankenphpRunning else { return .skipFrankenPHPStopped }
        return redirectWorking ? .skipRedirectAlreadyWorking : .reloadPF
    }

    /// The helper never prompts. Without it, `pfctl -ef /etc/pf.conf` behind an administrator
    /// prompt is only worth asking for when pf.conf already loads Nest's anchor, and not again
    /// after the user declined it (or it could not help) this session.
    public static func reloadMethod(helperEnabled: Bool, pfConfLoadsAnchor: Bool, promptAllowed: Bool) -> PFReloadMethod {
        if helperEnabled { return .helper }
        guard pfConfLoadsAnchor else { return .unavailable(.notWired) }
        return promptAllowed ? .administratorPrompt : .unavailable(.suppressed)
    }

    /// The manual (development) anchor and the one the privileged helper installs.
    public static let nestAnchors: [(name: String, path: String)] = [
        ("dev.nest.app", "/etc/pf.anchors/dev.nest.app"),
        ("app.nest", "/etc/pf.anchors/app.nest"),
    ]

    /// The Port Redirect (PF) environment check's criteria: pf.conf declares and loads one of
    /// Nest's anchors, and that anchor file exists. Commented-out lines do not count.
    public static func pfConfLoadsNestAnchor(_ content: String, anchorExists: (String) -> Bool) -> Bool {
        let statements = Set(content.split(whereSeparator: \.isNewline).map { line in
            (line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces)
        })
        return nestAnchors.contains { anchor in
            statements.contains("rdr-anchor \"\(anchor.name)\"")
                && statements.contains("load anchor \"\(anchor.name)\" from \"\(anchor.path)\"")
                && anchorExists(anchor.path)
        }
    }

    /// Classifies the `osascript … with administrator privileges` result. Cancelling the
    /// prompt fails with AppleScript error -128.
    public static func promptOutcome(status: Int32, output: String, redirectWorking: Bool) -> PortRedirectRepairOutcome {
        if status == 0 { return redirectWorking ? .repaired : .ineffective }
        if output.contains("(-128)") || output.localizedCaseInsensitiveContains("user canceled") { return .declined }
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(detail.isEmpty ? "exit status \(status)" : detail)
    }
}
