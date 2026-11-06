import Foundation

/// The pure `/etc/pf.conf` editing rules used by the root helper (`NestPFHelper`).
/// Kept free of file and process access so the exact text transformations can be tested.
public enum PFConfEditor {
    public static let anchorName = "app.nest"
    public static let anchorPath = "/etc/pf.anchors/\(anchorName)"
    public static let pfConfPath = "/etc/pf.conf"
    public static let pfConfBackupPath = "/etc/pf.conf.nest-backup"

    public static let anchorContents = """
    rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port 8080
    rdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port 8443

    """

    public static let anchorDeclaration = "rdr-anchor \"\(anchorName)\""
    public static let anchorLoad = "load anchor \"\(anchorName)\" from \"\(anchorPath)\""
    public static let markerStart = "# BEGIN NEST PF ANCHOR"
    public static let markerEnd = "# END NEST PF ANCHOR"
    public static let managedBlock = """
    \(markerStart)
    \(anchorDeclaration)
    \(anchorLoad)
    \(markerEnd)
    """

    public struct UnbalancedMarkers: Error, CustomStringConvertible {
        public init() {}
        public var description: String { "\(PFConfEditor.pfConfPath) has unbalanced Nest markers; refusing to edit it" }
    }

    /// Removes only Nest's own lines. A start marker without its end marker would otherwise
    /// swallow every rule after it, so that case is refused instead of guessed at.
    public static func removingManagedBlock(from content: String) throws -> String {
        var output: [String] = []
        var insideManagedBlock = false

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == markerStart {
                guard !insideManagedBlock else { throw UnbalancedMarkers() }
                insideManagedBlock = true
                continue
            }
            if trimmed == markerEnd {
                guard insideManagedBlock else { throw UnbalancedMarkers() }
                insideManagedBlock = false
                continue
            }
            if insideManagedBlock {
                guard trimmed.isEmpty || trimmed == anchorDeclaration || trimmed == anchorLoad else { throw UnbalancedMarkers() }
                continue
            }
            if trimmed == anchorDeclaration || trimmed == anchorLoad {
                continue
            }
            output.append(line)
        }

        guard !insideManagedBlock else { throw UnbalancedMarkers() }
        return output.joined(separator: "\n")
    }

    /// Places the block before the first anchor point (Apple's `rdr-anchor "com.apple/*"` in the
    /// stock file): pfctl rejects translation rules that come before `scrub-anchor`.
    public static func insertingManagedBlock(into content: String) throws -> String {
        let cleaned = try removingManagedBlock(from: content)
        var lines = cleaned.components(separatedBy: "\n")
        let insertIndex = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("rdr-anchor") || trimmed.hasPrefix("load anchor")
        } ?? lines.count

        lines.insert(contentsOf: managedBlock.components(separatedBy: "\n"), at: insertIndex)
        return lines.joined(separator: "\n")
    }

    /// Reads `pfctl -s info` output. `pfctl -E` takes a new enable reference on every call, so
    /// the helper enables PF only when it is off and otherwise just reloads the rules.
    public static func isEnabled(statusInfo: String) -> Bool {
        statusInfo.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("Status: Enabled")
        }
    }
}
