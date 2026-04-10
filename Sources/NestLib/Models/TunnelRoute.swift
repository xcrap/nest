import Foundation

public enum TunnelRouteKind: String, Codable, CaseIterable, Identifiable {
    case php
    case app

    public var id: String { rawValue }
}

public struct TunnelRoute: Codable, Identifiable, Equatable {
    public var id: String
    public var kind: TunnelRouteKind
    public var subdomain: String
    public var publicDomain: String
    public var localDomain: String
    public var originPort: Int
    public var active: Bool
    public var linkedSiteDomain: String?
    public var linkedProjectID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: TunnelRouteKind,
        subdomain: String,
        publicDomain: String,
        localDomain: String,
        originPort: Int,
        active: Bool = true,
        linkedSiteDomain: String? = nil,
        linkedProjectID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.subdomain = subdomain
        self.publicDomain = publicDomain
        self.localDomain = localDomain
        self.originPort = originPort
        self.active = active
        self.linkedSiteDomain = linkedSiteDomain
        self.linkedProjectID = linkedProjectID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case subdomain
        case publicDomain
        case localDomain
        case originPort
        case port
        case httpsPort
        case active
        case linkedSiteDomain
        case linkedProjectID
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try container.decode(TunnelRouteKind.self, forKey: .kind)
        subdomain = try container.decode(String.self, forKey: .subdomain)
        publicDomain = try container.decodeIfPresent(String.self, forKey: .publicDomain) ?? ""
        localDomain = try container.decodeIfPresent(String.self, forKey: .localDomain) ?? ""
        originPort = try container.decodeIfPresent(Int.self, forKey: .originPort)
            ?? container.decodeIfPresent(Int.self, forKey: .port)
            ?? container.decodeIfPresent(Int.self, forKey: .httpsPort)
            ?? (kind == .php ? 443 : 0)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        linkedSiteDomain = try container.decodeIfPresent(String.self, forKey: .linkedSiteDomain)
        linkedProjectID = try container.decodeIfPresent(String.self, forKey: .linkedProjectID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(subdomain, forKey: .subdomain)
        try container.encode(publicDomain, forKey: .publicDomain)
        try container.encode(localDomain, forKey: .localDomain)
        try container.encode(originPort, forKey: .originPort)
        try container.encode(active, forKey: .active)
        try container.encodeIfPresent(linkedSiteDomain, forKey: .linkedSiteDomain)
        try container.encodeIfPresent(linkedProjectID, forKey: .linkedProjectID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public var publicHostname: String {
        guard !publicDomain.isEmpty else { return subdomain }
        return "\(subdomain).\(publicDomain)"
    }

    public static func defaultID(from hostname: String) -> String {
        hostname.lowercased().replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
    }
}
