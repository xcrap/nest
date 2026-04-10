import Foundation

public struct AppSettings: Codable, Equatable {
    public var runtimePaths: RuntimePaths
    public var caddyConfigDirectory: String
    public var cloudflareSettings: CloudflareSettings
    public var mindProjectDirectory: String
    public var hasCompletedMindMigration: Bool

    public init(
        runtimePaths: RuntimePaths = RuntimePaths(),
        caddyConfigDirectory: String = "/opt/homebrew/etc",
        cloudflareSettings: CloudflareSettings = CloudflareSettings(),
        mindProjectDirectory: String = "",
        hasCompletedMindMigration: Bool = false
    ) {
        self.runtimePaths = runtimePaths
        self.caddyConfigDirectory = caddyConfigDirectory
        self.cloudflareSettings = cloudflareSettings
        self.mindProjectDirectory = mindProjectDirectory
        self.hasCompletedMindMigration = hasCompletedMindMigration
    }

    enum CodingKeys: String, CodingKey {
        case runtimePaths
        case caddyConfigDirectory
        case cloudflareSettings
        case mindProjectDirectory
        case hasCompletedMindMigration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimePaths = try container.decodeIfPresent(RuntimePaths.self, forKey: .runtimePaths) ?? RuntimePaths.detectDefaults()
        caddyConfigDirectory = try container.decodeIfPresent(String.self, forKey: .caddyConfigDirectory) ?? "/opt/homebrew/etc"
        cloudflareSettings = try container.decodeIfPresent(CloudflareSettings.self, forKey: .cloudflareSettings) ?? CloudflareSettings.detectDefaults()
        mindProjectDirectory = try container.decodeIfPresent(String.self, forKey: .mindProjectDirectory)
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("projects/mind")
        hasCompletedMindMigration = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedMindMigration) ?? false
    }

    public static func defaultSettings() -> AppSettings {
        return AppSettings(
            runtimePaths: RuntimePaths.detectDefaults(),
            caddyConfigDirectory: "/opt/homebrew/etc",
            cloudflareSettings: CloudflareSettings.detectDefaults(),
            mindProjectDirectory: (NSHomeDirectory() as NSString).appendingPathComponent("projects/mind"),
            hasCompletedMindMigration: false
        )
    }

    public static let developmentBundleIdentifier = "dev.nest.app"
    public static let productionBundleIdentifier = "app.nest"

    public static var currentBundleIdentifier: String {
        if let override = ProcessInfo.processInfo.environment["NEST_BUNDLE_ID"], !override.isEmpty {
            return override
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return developmentBundleIdentifier
    }

    public static var appSupportDirectory: String {
        NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first ?? ("~/Library/Application Support" as NSString).expandingTildeInPath
    }

    public static var storageRootName: String {
        switch currentBundleIdentifier {
        case developmentBundleIdentifier:
            return developmentBundleIdentifier
        case productionBundleIdentifier:
            return productionBundleIdentifier
        default:
            return currentBundleIdentifier
        }
    }

    public static var storageRootDirectory: String {
        (appSupportDirectory as NSString).appendingPathComponent(storageRootName)
    }

    public static var legacySharedRootDirectory: String {
        (appSupportDirectory as NSString).appendingPathComponent("Nest")
    }

    /// Path where Nest stores its own app data (sites.json, settings.json).
    public static var nestDataDirectory: String {
        (storageRootDirectory as NSString).appendingPathComponent("config")
    }

    public static var nestLogsDirectory: String {
        (storageRootDirectory as NSString).appendingPathComponent("logs")
    }

    public static var nestRunDirectory: String {
        (storageRootDirectory as NSString).appendingPathComponent("run")
    }

    public static var nestBinDirectory: String {
        (storageRootDirectory as NSString).appendingPathComponent("bin")
    }

    public static func prepareStorage(fileManager: FileManager = .default) {
        migrateLegacySharedDataIfNeeded(fileManager: fileManager)

        let directories = [
            storageRootDirectory,
            nestDataDirectory,
            nestLogsDirectory,
            nestRunDirectory
        ]

        for directory in directories {
            try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
    }

    private static func migrateLegacySharedDataIfNeeded(fileManager: FileManager = .default) {
        let legacyPath = legacySharedRootDirectory
        let currentPath = storageRootDirectory

        guard currentPath != legacyPath else { return }
        guard fileManager.fileExists(atPath: legacyPath) else { return }
        guard !fileManager.fileExists(atPath: currentPath) else { return }

        try? fileManager.copyItem(atPath: legacyPath, toPath: currentPath)
    }
}
