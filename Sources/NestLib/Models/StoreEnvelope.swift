import Foundation

public enum StoreSchema {
    public static let currentVersion = 1
}

public struct StoreEnvelope<Payload: Codable>: Codable {
    public var schemaVersion: Int
    public var savedAt: Date
    public var payload: Payload

    public init(
        schemaVersion: Int = StoreSchema.currentVersion,
        savedAt: Date = Date(),
        payload: Payload
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.payload = payload
    }
}
