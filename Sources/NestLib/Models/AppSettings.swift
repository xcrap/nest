import Foundation

public struct AppSettings: Codable, Equatable {
    public var runtimePaths: RuntimePaths
    public var caddyConfigDirectory: String

    public init(
        runtimePaths: RuntimePaths = RuntimePaths(),
        caddyConfigDirectory: String = "/opt/homebrew/etc"
    ) {
        self.runtimePaths = runtimePaths
        self.caddyConfigDirectory = caddyConfigDirectory
    }

    public static func defaultSettings() -> AppSettings {
        return AppSettings(
            runtimePaths: RuntimePaths.detectDefaults(),
            caddyConfigDirectory: "/opt/homebrew/etc"
        )
    }

    /// Path where Nest stores its own app data (sites.json, settings.json).
    public static var nestDataDirectory: String {
        let appSupport = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first ?? ("~/Library/Application Support" as NSString).expandingTildeInPath
        return (appSupport as NSString).appendingPathComponent("Nest/config")
    }
}
