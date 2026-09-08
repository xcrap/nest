import Foundation

public struct CloudflareSettings: Codable, Equatable {
    public var apiToken: String
    public var zoneId: String
    public var accountId: String
    public var tunnelId: String
    public var tunnelName: String
    public var tunnelDomain: String
    public var configPath: String
    public var credentialsFilePath: String

    public init(
        apiToken: String = "",
        zoneId: String = "",
        accountId: String = "",
        tunnelId: String = "",
        tunnelName: String = "",
        tunnelDomain: String = "",
        configPath: String = "",
        credentialsFilePath: String = ""
    ) {
        self.apiToken = apiToken
        self.zoneId = zoneId
        self.accountId = accountId
        self.tunnelId = tunnelId
        self.tunnelName = tunnelName
        self.tunnelDomain = tunnelDomain
        self.configPath = configPath
        self.credentialsFilePath = credentialsFilePath
    }

    enum CodingKeys: String, CodingKey { case apiToken, zoneId, accountId, tunnelId, tunnelName, tunnelDomain, configPath, credentialsFilePath }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiToken = try values.decodeIfPresent(String.self, forKey: .apiToken) ?? "" // Legacy import only.
        zoneId = try values.decodeIfPresent(String.self, forKey: .zoneId) ?? ""
        accountId = try values.decodeIfPresent(String.self, forKey: .accountId) ?? ""
        tunnelId = try values.decodeIfPresent(String.self, forKey: .tunnelId) ?? ""
        tunnelName = try values.decodeIfPresent(String.self, forKey: .tunnelName) ?? ""
        tunnelDomain = try values.decodeIfPresent(String.self, forKey: .tunnelDomain) ?? ""
        configPath = try values.decodeIfPresent(String.self, forKey: .configPath) ?? ""
        credentialsFilePath = try values.decodeIfPresent(String.self, forKey: .credentialsFilePath) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(zoneId, forKey: .zoneId)
        try values.encode(accountId, forKey: .accountId)
        try values.encode(tunnelId, forKey: .tunnelId)
        try values.encode(tunnelName, forKey: .tunnelName)
        try values.encode(tunnelDomain, forKey: .tunnelDomain)
        try values.encode(configPath, forKey: .configPath)
        try values.encode(credentialsFilePath, forKey: .credentialsFilePath)
    }

    public static func detectDefaults(homeDirectory: String = NSHomeDirectory()) -> CloudflareSettings {
        let configDirectory = (homeDirectory as NSString).appendingPathComponent(".cloudflared")
        let yamlPath = (configDirectory as NSString).appendingPathComponent("config.yaml")
        let ymlPath = (configDirectory as NSString).appendingPathComponent("config.yml")
        let configPath = FileManager.default.fileExists(atPath: yamlPath) ? yamlPath : ymlPath

        var settings = CloudflareSettings(
            configPath: configPath.isEmpty ? yamlPath : configPath
        )

        if let content = try? String(contentsOfFile: settings.configPath, encoding: .utf8) {
            if let tunnelName = value(in: content, for: "tunnel") {
                settings.tunnelName = tunnelName
            }
            if let credentials = value(in: content, for: "credentials-file") {
                settings.credentialsFilePath = credentials
                if settings.tunnelId.isEmpty {
                    settings.tunnelId = URL(fileURLWithPath: credentials).deletingPathExtension().lastPathComponent
                }
            }
        }

        if settings.credentialsFilePath.isEmpty,
           let jsonPath = try? FileManager.default.contentsOfDirectory(atPath: configDirectory)
            .map({ (configDirectory as NSString).appendingPathComponent($0) })
            .first(where: { $0.hasSuffix(".json") }) {
            settings.credentialsFilePath = jsonPath
            settings.tunnelId = URL(fileURLWithPath: jsonPath).deletingPathExtension().lastPathComponent
        }

        if settings.tunnelDomain.isEmpty, !settings.tunnelId.isEmpty {
            settings.tunnelDomain = "\(settings.tunnelId).cfargotunnel.com"
        }

        return settings
    }

    public var hasLocalConfiguration: Bool {
        !tunnelName.isEmpty && !configPath.isEmpty && !credentialsFilePath.isEmpty
    }

    public var hasAPIConfiguration: Bool {
        !apiToken.isEmpty && !zoneId.isEmpty && !accountId.isEmpty && !tunnelId.isEmpty && !tunnelDomain.isEmpty
    }

    private static func value(in content: String, for key: String) -> String? {
        content
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("\(key):") else { return nil }
                return trimmed
                    .replacingOccurrences(of: "\(key):", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first
    }
}
