import Foundation

public struct AppProject: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var hostname: String
    public var directory: String
    public var port: Int
    public var command: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        hostname: String,
        directory: String,
        port: Int,
        command: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.directory = directory
        self.port = port
        self.command = command
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case hostname
        case directory
        case dir
        case port
        case command
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        hostname = try container.decode(String.self, forKey: .hostname)
        directory = try container.decodeIfPresent(String.self, forKey: .directory)
            ?? container.decodeIfPresent(String.self, forKey: .dir)
            ?? ""
        port = try container.decode(Int.self, forKey: .port)
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(directory, forKey: .directory)
        try container.encode(port, forKey: .port)
        try container.encode(command, forKey: .command)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public var launchAgentLabel: String {
        let namespace = AppSettings.storageRootName.replacingOccurrences(of: ".", with: "-")
        return "app.nest.\(namespace).project.\(sanitizedID)"
    }

    public var logPath: String {
        let projectsDirectory = (AppSettings.nestLogsDirectory as NSString).appendingPathComponent("projects")
        return (projectsDirectory as NSString).appendingPathComponent("\(sanitizedID).log")
    }

    public var sanitizedID: String {
        id.lowercased().replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
    }

    public static func defaultID(from name: String) -> String {
        let value = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
