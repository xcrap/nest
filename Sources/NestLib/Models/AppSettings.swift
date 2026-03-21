import Foundation

public struct AppSettings: Codable, Equatable {
    public var runtimePaths: RuntimePaths
    public var configDirectory: String
    public var dataDirectory: String
    public var defaultDocumentRoot: String?

    public init(
        runtimePaths: RuntimePaths = RuntimePaths(),
        configDirectory: String = "",
        dataDirectory: String = "",
        defaultDocumentRoot: String? = nil
    ) {
        self.runtimePaths = runtimePaths
        self.configDirectory = configDirectory
        self.dataDirectory = dataDirectory
    }

    public static func defaultSettings() -> AppSettings {
        let appSupport = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first ?? ("~/Library/Application Support" as NSString).expandingTildeInPath

        let nestDir = (appSupport as NSString).appendingPathComponent("Nest")

        return AppSettings(
            runtimePaths: RuntimePaths.detectDefaults(),
            configDirectory: (nestDir as NSString).appendingPathComponent("config"),
            dataDirectory: (nestDir as NSString).appendingPathComponent("data")
        )
    }
}
