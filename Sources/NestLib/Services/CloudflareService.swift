import Foundation

public struct CloudflareDNSRecord: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var type: String
    public var content: String
    public var proxied: Bool
    public var ttl: Int

    public init(id: String, name: String, type: String, content: String, proxied: Bool, ttl: Int) {
        self.id = id
        self.name = name
        self.type = type
        self.content = content
        self.proxied = proxied
        self.ttl = ttl
    }
}

public enum CloudflareServiceError: LocalizedError {
    case missingAPIConfiguration
    case missingLocalConfiguration
    case requestFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIConfiguration:
            return "Cloudflare API settings are incomplete."
        case .missingLocalConfiguration:
            return "Cloudflare tunnel settings are incomplete."
        case .requestFailed(let message):
            return message
        case .invalidResponse:
            return "Cloudflare returned an invalid response."
        }
    }
}

private struct CloudflareAPIResponse<ResultType: Decodable>: Decodable {
    var success: Bool
    var result: ResultType?
    var errors: [CloudflareAPIError]
}

private struct CloudflareEmptyPayload: Decodable {}

private struct CloudflareAPIError: Decodable {
    var code: Int?
    var message: String
}

private struct CloudflareTunnelConfigurationPayload: Encodable {
    var config: Configuration

    struct Configuration: Encodable {
        var ingress: [IngressRule]
        var warpRouting: WarpRouting

        enum CodingKeys: String, CodingKey {
            case ingress
            case warpRouting = "warp-routing"
        }
    }

    struct IngressRule: Encodable {
        var hostname: String
        var service: String
        var originRequest: OriginRequest
    }

    struct OriginRequest: Encodable {
        var noTLSVerify: Bool?
        var httpHostHeader: String
    }

    struct WarpRouting: Encodable {
        var enabled: Bool
    }
}

public enum CloudflareService {
    public static func listDNSRecords(settings: CloudflareSettings) async throws -> [CloudflareDNSRecord] {
        guard settings.hasAPIConfiguration else {
            throw CloudflareServiceError.missingAPIConfiguration
        }

        let url = URL(string: "https://api.cloudflare.com/client/v4/zones/\(settings.zoneId)/dns_records?type=CNAME&per_page=100")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(CloudflareAPIResponse<[CloudflareDNSRecord]>.self, from: data)

        guard response.success, let records = response.result else {
            let message = response.errors.map(\.message).joined(separator: ", ")
            throw CloudflareServiceError.requestFailed(message.isEmpty ? "Cloudflare request failed." : message)
        }

        return records
            .filter { $0.content == settings.tunnelDomain }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func createDNSRecord(subdomain: String, settings: CloudflareSettings) async throws {
        guard settings.hasAPIConfiguration else {
            throw CloudflareServiceError.missingAPIConfiguration
        }

        let url = URL(string: "https://api.cloudflare.com/client/v4/zones/\(settings.zoneId)/dns_records")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "type": "CNAME",
            "name": subdomain,
            "content": settings.tunnelDomain,
            "proxied": true,
            "ttl": 1
        ])

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(CloudflareAPIResponse<CloudflareEmptyPayload>.self, from: data)
        guard response.success else {
            let message = response.errors.map(\.message).joined(separator: ", ")
            throw CloudflareServiceError.requestFailed(message.isEmpty ? "Failed to create DNS record." : message)
        }
    }

    public static func deleteDNSRecord(id: String, settings: CloudflareSettings) async throws {
        guard settings.hasAPIConfiguration else {
            throw CloudflareServiceError.missingAPIConfiguration
        }

        let url = URL(string: "https://api.cloudflare.com/client/v4/zones/\(settings.zoneId)/dns_records/\(id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(CloudflareAPIResponse<CloudflareEmptyPayload>.self, from: data)
        guard response.success else {
            let message = response.errors.map(\.message).joined(separator: ", ")
            throw CloudflareServiceError.requestFailed(message.isEmpty ? "Failed to delete DNS record." : message)
        }
    }

    public static func pushTunnelConfiguration(
        settings: CloudflareSettings,
        routes: [TunnelRoute],
        sites: [Site],
        projects: [AppProject]
    ) async throws {
        guard settings.hasLocalConfiguration else {
            throw CloudflareServiceError.missingLocalConfiguration
        }
        guard settings.hasAPIConfiguration else {
            throw CloudflareServiceError.missingAPIConfiguration
        }

        let renderer = TunnelConfigRenderer(settings: settings)
        let resolvedRoutes = renderer.resolvedRoutes(routes: routes, sites: sites, projects: projects)
        let payload = CloudflareTunnelConfigurationPayload(
            config: .init(
                ingress: resolvedRoutes.map {
                    .init(
                        hostname: $0.hostname,
                        service: $0.service,
                        originRequest: .init(
                            noTLSVerify: $0.noTLSVerify ? true : nil,
                            httpHostHeader: $0.httpHostHeader
                        )
                    )
                } + [
                    .init(
                        hostname: "",
                        service: "http_status:404",
                        originRequest: .init(noTLSVerify: nil, httpHostHeader: "")
                    )
                ],
                warpRouting: .init(enabled: false)
            )
        )

        let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(settings.accountId)/cfd_tunnel/\(settings.tunnelId)/configurations")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(CloudflareAPIResponse<CloudflareEmptyPayload>.self, from: data)
        guard response.success else {
            let message = response.errors.map(\.message).joined(separator: ", ")
            throw CloudflareServiceError.requestFailed(message.isEmpty ? "Failed to push tunnel configuration." : message)
        }
    }
}
