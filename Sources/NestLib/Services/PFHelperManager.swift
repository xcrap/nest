import Foundation
import ServiceManagement

public enum PFHelperStatus: Equatable {
    case unsupported
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
    case unknown
}

public enum PFHelperManager {
    public static let plistName = "app.nest.pfhelper.plist"
    public static let serviceLabel = "app.nest.pfhelper"
    public static let kickPath = "/tmp/app.nest.pfhelper.kick"
    public static let anchorPath = "/etc/pf.anchors/app.nest"

    /// The helper daemon can only be registered from a Developer-ID-signed prod build.
    /// Dev builds (ad-hoc signed) fall back to the legacy osascript flow.
    public static var isSupported: Bool {
        AppSettings.currentBundleIdentifier == AppSettings.productionBundleIdentifier
    }

    public static var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    public static var status: PFHelperStatus {
        guard isSupported else { return .unsupported }
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    /// Register the daemon with launchd. User will see a macOS prompt to approve
    /// in System Settings → Login Items & Extensions the first time.
    public static func register() throws {
        guard isSupported else { return }
        try service.register()
    }

    public static func unregister() throws {
        guard isSupported else { return }
        try service.unregister()
    }

    /// Ask launchd to re-run the daemon by touching the WatchPaths file.
    /// No prompt, no root — launchd watches /tmp/app.nest.pfhelper.kick.
    @discardableResult
    public static func kickstart() -> Bool {
        guard isSupported else { return false }
        guard status == .enabled else { return false }
        let data = Data("kick\n".utf8)
        do {
            try data.write(to: URL(fileURLWithPath: kickPath))
            return true
        } catch {
            return false
        }
    }

    /// Open System Settings so the user can approve the daemon.
    public static func openLoginItemsSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
