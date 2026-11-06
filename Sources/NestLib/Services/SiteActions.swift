import AppKit
import UniformTypeIdentifiers

public enum SiteActions {
    /// An installed app Nest can hand a folder to.
    public struct ExternalApp: Sendable {
        public let name: String
        public let url: URL
    }

    private static let terminalBundleID = "com.apple.Terminal"
    /// Terminals known to open a folder passed as a document in a new window at that folder.
    private static let folderCapableTerminals: Set<String> = [
        terminalBundleID,
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty",
    ]
    /// Editors tried in order for "Open in Editor".
    private static let editorBundleIDs = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",
    ]

    public static func open(_ site: Site) {
        if let url = URL(string: "https://\(site.domain)") { NSWorkspace.shared.open(url) }
    }
    public static func reveal(_ site: Site) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: site.rootPath)
    }

    /// The user's terminal: the app registered to run shell scripts when it is a terminal
    /// that can open folders (iTerm2, Warp, Ghostty set this when made the default), else Terminal.
    public static var terminalApp: ExternalApp? {
        let workspace = NSWorkspace.shared
        let candidates = ["com.apple.terminal.shell-script", "public.unix-executable"]
            .compactMap { UTType($0) }
            .compactMap { workspace.urlForApplication(toOpen: $0) }
        let preferred = candidates.first { url in
            guard let id = Bundle(url: url)?.bundleIdentifier else { return false }
            return id != terminalBundleID && folderCapableTerminals.contains(id)
        }
        guard let url = preferred ?? workspace.urlForApplication(withBundleIdentifier: terminalBundleID) else { return nil }
        return ExternalApp(name: displayName(of: url), url: url)
    }

    /// The first installed of Visual Studio Code, Cursor and Zed, or nil when none is.
    public static var editorApp: ExternalApp? {
        for id in editorBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return ExternalApp(name: displayName(of: url), url: url)
            }
        }
        return nil
    }

    public static func terminal(_ site: Site) {
        guard let terminal = terminalApp else { return }
        let folder = URL(fileURLWithPath: site.rootPath, isDirectory: true)
        let isFallback = Bundle(url: terminal.url)?.bundleIdentifier == terminalBundleID
        NSWorkspace.shared.open([folder], withApplicationAt: terminal.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            // Fall back to Terminal if the preferred terminal refuses the folder.
            guard error != nil, !isFallback,
                  let fallback = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else { return }
            NSWorkspace.shared.open([folder], withApplicationAt: fallback, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    public static func editor(_ site: Site) {
        guard let editor = editorApp else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: site.rootPath, isDirectory: true)], withApplicationAt: editor.url,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private static func displayName(of appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
    }
}
