import AppKit

public enum SiteActions {
    public static func open(_ site: Site) {
        if let url = URL(string: "https://\(site.domain)") { NSWorkspace.shared.open(url) }
    }
    public static func reveal(_ site: Site) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: site.rootPath)
    }
    public static func terminal(_ site: Site) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: site.rootPath)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
