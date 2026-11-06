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
    case invalidTunnelConfiguration([String])
    case requestFailed(String)
    case invalidResponse
    case invalidIdentifiers([String])
    case hostnameOutsideZone(hostname: String, zone: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIConfiguration:
            return "Cloudflare API settings are incomplete."
        case .missingLocalConfiguration:
            return "Cloudflare tunnel settings are incomplete."
        case .invalidTunnelConfiguration(let issues):
            return "Cloudflare tunnel configuration is invalid: \(issues.joined(separator: " "))"
        case .requestFailed(let message):
            return message
        case .invalidResponse:
            return "Cloudflare returned an invalid response."
        case .invalidIdentifiers(let issues):
            return "Cloudflare API settings are invalid: \(issues.joined(separator: " "))"
        case .hostnameOutsideZone(let hostname, let zone):
            return CloudflareService.zoneMismatchMessage(hostname: hostname, zone: zone)
        }
    }
}

private struct CloudflareAPIResponse<ResultType: Decodable>: Decodable {
    var success: Bool
    var result: ResultType?
    var errors: [CloudflareAPIError]
    var resultInfo: ResultInfo?

    struct ResultInfo: Decodable {
        var page: Int?
        var totalPages: Int?

        enum CodingKeys: String, CodingKey {
            case page
            case totalPages = "total_pages"
        }
    }

    enum CodingKeys: String, CodingKey {
        case success, result, errors
        case resultInfo = "result_info"
    }
}

private struct CloudflareRemoteTunnelConfiguration: Decodable {
    var config: Configuration?

    struct Configuration: Decodable {
        var warpRouting: WarpRouting?

        enum CodingKeys: String, CodingKey {
            case warpRouting = "warp-routing"
        }
    }

    struct WarpRouting: Decodable {
        var enabled: Bool?
    }
}

private struct CloudflareEmptyPayload: Decodable {}

private struct CloudflareZone: Decodable {
    var name: String
}

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

/// Zone names never change for a zone ID, so one lookup per process is enough.
private final class CloudflareZoneNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]

    func name(for zoneId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return names[zoneId.lowercased()]
    }

    func store(_ name: String, for zoneId: String) {
        lock.lock(); defer { lock.unlock() }
        names[zoneId.lowercased()] = name
    }
}

public enum CloudflareService {
    /// Cloudflare calls fail within this many seconds instead of URLSession's 60 s default,
    /// so a save never appears to hang on an unreachable API.
    public static let requestTimeout: TimeInterval = 20

    /// The session every Cloudflare call uses unless a caller injects its own (tests use a stub).
    /// Ephemeral: API responses and credentials never land in an on-disk cache.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 3
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// How many per-hostname DNS lookups run at once during a publish.
    public static let dnsLookupConcurrency = 4

    private static let apiBase = "https://api.cloudflare.com/client/v4"
    private static let zoneNames = CloudflareZoneNameCache()

    // MARK: - Validation

    /// Zone and account IDs are 32 hexadecimal characters.
    public static func isValidHexIdentifier(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy(isHexDigit)
    }

    /// Tunnel IDs are UUIDs (`cloudflared` names the credentials file after them); the
    /// undashed 32-character form is accepted too.
    public static func isValidTunnelIdentifier(_ value: String) -> Bool {
        if isValidHexIdentifier(value) { return true }
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        return groups.map(\.utf8.count) == [8, 4, 4, 4, 12] && groups.allSatisfy { $0.utf8.allSatisfy(isHexDigit) }
    }

    /// Problems with the IDs Nest interpolates into Cloudflare API URLs. Empty fields are
    /// reported by `hasAPIConfiguration` instead, so they are skipped here.
    public static func identifierIssues(_ settings: CloudflareSettings, zone: Bool = true, tunnel: Bool = true) -> [String] {
        var issues: [String] = []
        if zone, !settings.zoneId.isEmpty, !isValidHexIdentifier(settings.zoneId) {
            issues.append("Zone ID must be the 32-character hexadecimal ID shown on the zone's Overview page.")
        }
        if tunnel, !settings.accountId.isEmpty, !isValidHexIdentifier(settings.accountId) {
            issues.append("Account ID must be the 32-character hexadecimal ID shown on the zone's Overview page.")
        }
        if tunnel, !settings.tunnelId.isEmpty, !isValidTunnelIdentifier(settings.tunnelId) {
            issues.append("Tunnel ID must be the tunnel's UUID (for example 6ff42ae2-765d-4adf-8112-31c55c1551ef).")
        }
        return issues
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func requireAPI(_ settings: CloudflareSettings, zone: Bool = true, tunnel: Bool = false) throws {
        guard settings.hasAPIConfiguration else { throw CloudflareServiceError.missingAPIConfiguration }
        let issues = identifierIssues(settings, zone: zone, tunnel: tunnel)
        guard issues.isEmpty else { throw CloudflareServiceError.invalidIdentifiers(issues) }
    }

    /// True when `hostname` is the zone apex or one of its subdomains.
    public static func isHostname(_ hostname: String, inZone zone: String) -> Bool {
        let host = NestValidation.normalizedDomain(hostname)
        let zone = NestValidation.normalizedDomain(zone)
        guard !host.isEmpty, !zone.isEmpty else { return false }
        return host == zone || host.hasSuffix(".\(zone)")
    }

    /// Cloudflare treats a name outside the zone as relative to it, so `app.other.org` in
    /// zone `example.com` would become `app.other.org.example.com`.
    public static func zoneMismatchMessage(hostname: String, zone: String) -> String {
        "\(hostname) is outside the Cloudflare zone \(zone). Use \(zone) or a subdomain of it, or set the Zone ID of the zone that owns this hostname."
    }

    /// The validation message for a hostname, or nil when it belongs to the zone.
    public static func zoneIssue(hostname: String, zone: String) -> String? {
        isHostname(hostname, inZone: zone) ? nil : zoneMismatchMessage(hostname: hostname, zone: zone)
    }

    // MARK: - Requests

    private static func apiRequest(_ url: URL, method: String = "GET", settings: CloudflareSettings, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = method
        request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private static func decodeAPIResponse<ResultType: Decodable>(
        _ resultType: ResultType.Type,
        data: Data,
        response: URLResponse,
        defaultFailureMessage: String,
        requireResult: Bool = true
    ) throws -> ResultType? {
        try decodeAPIEnvelope(resultType, data: data, response: response,
                              defaultFailureMessage: defaultFailureMessage, requireResult: requireResult).result
    }

    private static func decodeAPIEnvelope<ResultType: Decodable>(
        _ resultType: ResultType.Type,
        data: Data,
        response: URLResponse,
        defaultFailureMessage: String,
        requireResult: Bool = true
    ) throws -> CloudflareAPIResponse<ResultType> {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudflareServiceError.invalidResponse
        }

        let decoded: CloudflareAPIResponse<ResultType>
        do {
            decoded = try JSONDecoder().decode(CloudflareAPIResponse<ResultType>.self, from: data)
        } catch {
            // Proxies and outages answer with HTML; keep the status so the failure is readable.
            let body = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CloudflareServiceError.requestFailed("Cloudflare HTTP \(httpResponse.statusCode): \(body.isEmpty ? defaultFailureMessage : body)")
        }
        let message = decoded.errors.map { error in
            if let code = error.code {
                return "\(code): \(error.message)"
            }
            return error.message
        }.joined(separator: ", ")

        guard (200..<300).contains(httpResponse.statusCode), decoded.success else {
            let failure = message.isEmpty ? defaultFailureMessage : message
            throw CloudflareServiceError.requestFailed("Cloudflare HTTP \(httpResponse.statusCode): \(failure)")
        }

        if requireResult, decoded.result == nil {
            throw CloudflareServiceError.invalidResponse
        }

        return decoded
    }

    // MARK: - Zone

    /// The zone's domain name (e.g. `example.com`), fetched once per zone ID and kept in memory.
    public static func zoneName(settings: CloudflareSettings, session: URLSession = defaultSession) async throws -> String {
        try requireAPI(settings)
        if let cached = zoneNames.name(for: settings.zoneId) { return cached }
        let url = URL(string: "\(apiBase)/zones/\(settings.zoneId)")!
        let (data, response) = try await session.data(for: apiRequest(url, settings: settings))
        let zone = try decodeAPIResponse(CloudflareZone.self, data: data, response: response,
            defaultFailureMessage: "Could not read the Cloudflare zone.")
        let name = NestValidation.normalizedDomain(zone?.name ?? "")
        guard NestValidation.domainIssues(name, field: "Zone name").isEmpty else {
            throw CloudflareServiceError.invalidResponse
        }
        zoneNames.store(name, for: settings.zoneId)
        return name
    }

    /// The zone name if an earlier call already looked it up; never touches the network.
    public static func cachedZoneName(zoneId: String) -> String? {
        zoneNames.name(for: zoneId)
    }

    // MARK: - DNS records

    /// Every CNAME pointing at this tunnel, following Cloudflare's pagination.
    public static func listDNSRecords(settings: CloudflareSettings, session: URLSession = defaultSession) async throws -> [CloudflareDNSRecord] {
        try requireAPI(settings)

        var records: [CloudflareDNSRecord] = []
        var page = 1
        var totalPages = 1
        repeat {
            var components = URLComponents(string: "\(apiBase)/zones/\(settings.zoneId)/dns_records")!
            components.queryItems = [
                URLQueryItem(name: "type", value: "CNAME"),
                URLQueryItem(name: "content", value: settings.tunnelDomain),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ]
            let (data, response) = try await session.data(for: apiRequest(components.url!, settings: settings))
            let envelope = try decodeAPIEnvelope(
                [CloudflareDNSRecord].self,
                data: data,
                response: response,
                defaultFailureMessage: "Cloudflare request failed."
            )
            let pageRecords = envelope.result ?? []
            records += pageRecords
            totalPages = envelope.resultInfo?.totalPages ?? 1
            page += 1
            // An empty page means the listing ended, whatever total_pages claimed.
            if pageRecords.isEmpty { break }
        } while page <= totalPages && page <= 100

        return records
            .filter { normalizedContent($0.content) == normalizedContent(settings.tunnelDomain) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func createDNSRecord(subdomain: String, settings: CloudflareSettings, session: URLSession = defaultSession) async throws {
        try requireAPI(settings)

        let url = URL(string: "\(apiBase)/zones/\(settings.zoneId)/dns_records")!
        let body = try JSONSerialization.data(withJSONObject: [
            "type": "CNAME",
            "name": subdomain,
            "content": settings.tunnelDomain,
            "proxied": true,
            "ttl": 1
        ])
        let (data, response) = try await session.data(for: apiRequest(url, method: "POST", settings: settings, body: body))
        _ = try decodeAPIResponse(
            CloudflareEmptyPayload.self,
            data: data,
            response: response,
            defaultFailureMessage: "Failed to create DNS record.",
            requireResult: false
        )
    }

    /// Idempotent publication: reuse only a proxied CNAME to this tunnel. Never take over
    /// an existing address or a hostname belonging to a different service, and never create
    /// a record for a hostname outside the configured zone.
    public static func ensureTunnelDNS(hostname: String, settings: CloudflareSettings, session: URLSession = defaultSession) async throws {
        try requireAPI(settings)
        let issues = NestValidation.domainIssues(hostname, field: "Public hostname")
        guard issues.isEmpty else { throw CloudflareServiceError.invalidTunnelConfiguration(issues) }
        let zone = try await zoneName(settings: settings, session: session)
        guard isHostname(hostname, inZone: zone) else {
            throw CloudflareServiceError.hostnameOutsideZone(hostname: hostname, zone: zone)
        }
        try await ensureTunnelDNSRecord(hostname: hostname, settings: settings, session: session)
    }

    /// The per-hostname lookup, without the zone check its callers already made.
    private static func ensureTunnelDNSRecord(hostname: String, settings: CloudflareSettings, session: URLSession) async throws {
        var components = URLComponents(string: "\(apiBase)/zones/\(settings.zoneId)/dns_records")!
        components.queryItems = [URLQueryItem(name: "name", value: hostname), URLQueryItem(name: "per_page", value: "100")]
        let (data, response) = try await session.data(for: apiRequest(components.url!, settings: settings))
        let records = try decodeAPIResponse([CloudflareDNSRecord].self, data: data, response: response,
            defaultFailureMessage: "Could not check DNS for \(hostname).") ?? []
        if records.isEmpty {
            try await createDNSRecord(subdomain: hostname, settings: settings, session: session)
        } else if !records.contains(where: { isTunnelRecord($0, hostname: hostname, settings: settings) }) {
            throw ConfigurationFailure("\(hostname) already has a DNS record that does not point to this tunnel with proxying enabled. Review it in Cloudflare; Nest left it unchanged.")
        }
    }

    private static func normalizedContent(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func isTunnelRecord(_ record: CloudflareDNSRecord, hostname: String, settings: CloudflareSettings) -> Bool {
        record.name.lowercased() == hostname.lowercased() && record.type == "CNAME" && record.proxied
            && normalizedContent(record.content) == normalizedContent(settings.tunnelDomain)
    }

    /// Makes sure every hostname has a proxied CNAME to this tunnel and returns the hostnames
    /// that could not be set up, with the reason. One listing covers hostnames that are
    /// already published; only the rest are looked up by name, a few at a time.
    public static func ensureTunnelDNS(
        hostnames: [String],
        settings: CloudflareSettings,
        session: URLSession = defaultSession
    ) async throws -> [(hostname: String, reason: String)] {
        try requireAPI(settings)
        var seen = Set<String>()
        let unique = hostnames.map { NestValidation.normalizedDomain($0) }.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return [] }

        var failures: [String: String] = [:]
        let zone: String
        do {
            zone = try await zoneName(settings: settings, session: session)
        } catch {
            let reason = "Could not read the Cloudflare zone to verify hostnames (\(error.localizedDescription)). Check the Zone ID and that the API token can read this zone."
            return unique.map { ($0, reason) }
        }

        var candidates: [String] = []
        for hostname in unique {
            if let issue = NestValidation.domainIssues(hostname, field: "Public hostname").first {
                failures[hostname] = issue
            } else if let issue = zoneIssue(hostname: hostname, zone: zone) {
                failures[hostname] = issue
            } else {
                candidates.append(hostname)
            }
        }

        // A failed listing only costs speed: every hostname is then checked by name.
        let published = Set(((try? await listDNSRecords(settings: settings, session: session)) ?? [])
            .filter { $0.type == "CNAME" && $0.proxied }
            .map { NestValidation.normalizedDomain($0.name) })
        let remaining = candidates.filter { !published.contains($0) }

        await withTaskGroup(of: (String, String?).self) { group in
            var queue = remaining.makeIterator()
            func enqueue(_ hostname: String) {
                group.addTask {
                    do {
                        try await ensureTunnelDNSRecord(hostname: hostname, settings: settings, session: session)
                        return (hostname, nil)
                    } catch {
                        return (hostname, error.localizedDescription)
                    }
                }
            }
            for _ in 0..<max(1, dnsLookupConcurrency) {
                guard let hostname = queue.next() else { break }
                enqueue(hostname)
            }
            while let (hostname, failure) = await group.next() {
                if let failure { failures[hostname] = failure }
                if let next = queue.next() { enqueue(next) }
            }
        }

        return unique.compactMap { hostname in failures[hostname].map { (hostname, $0) } }
    }

    /// Publishes DNS and the ingress list. One hostname's DNS problem never holds back the
    /// rest: the ingress (including removed or disabled routes) is always pushed, and the
    /// failed hostnames are reported together afterwards.
    public static func publishTunnel(
        settings: CloudflareSettings,
        routes: [TunnelRoute],
        sites: [Site],
        projects: [AppProject],
        session: URLSession = defaultSession
    ) async throws {
        guard settings.hasLocalConfiguration else { throw CloudflareServiceError.missingLocalConfiguration }
        try requireAPI(settings, zone: true, tunnel: true)
        let issues = TunnelConfigRenderer(settings: settings).validationIssues(routes: routes, sites: sites, projects: projects)
        guard issues.isEmpty else { throw CloudflareServiceError.invalidTunnelConfiguration(issues) }

        let failures = try await ensureTunnelDNS(
            hostnames: routes.filter(\.active).map(\.publicHostname), settings: settings, session: session)
        let failureSummary = summarize(failures)

        do {
            try await pushTunnelConfiguration(settings: settings, routes: routes, sites: sites, projects: projects, session: session)
        } catch {
            if failures.isEmpty {
                throw ConfigurationFailure("DNS is ready, but publishing routes failed: \(error.localizedDescription)")
            }
            throw ConfigurationFailure("Publishing routes failed: \(error.localizedDescription). DNS setup also failed for \(failureSummary)")
        }

        guard failures.isEmpty else {
            throw ConfigurationFailure("DNS setup failed for \(failureSummary) The route list was still published, so other hostnames are ready; retry is safe.")
        }
    }

    /// "2 hostnames: a.example.com, b.example.com. <each distinct reason once>"
    private static func summarize(_ failures: [(hostname: String, reason: String)]) -> String {
        let count = failures.count == 1 ? "1 hostname" : "\(failures.count) hostnames"
        var reasons: [String] = []
        for failure in failures where !reasons.contains(failure.reason) { reasons.append(failure.reason) }
        let sentences = reasons.map { $0.hasSuffix(".") ? $0 : "\($0)." }
        return "\(count): \(failures.map(\.hostname).joined(separator: ", ")). \(sentences.joined(separator: " "))"
    }

    public static func deleteDNSRecord(id: String, settings: CloudflareSettings, session: URLSession = defaultSession) async throws {
        try requireAPI(settings)
        guard !id.isEmpty, id.utf8.allSatisfy({ isHexDigit($0) || $0 == UInt8(ascii: "-") }) else {
            throw CloudflareServiceError.invalidIdentifiers(["DNS record ID \"\(id)\" is not a Cloudflare record ID."])
        }

        let url = URL(string: "\(apiBase)/zones/\(settings.zoneId)/dns_records/\(id)")!
        let (data, response) = try await session.data(for: apiRequest(url, method: "DELETE", settings: settings))
        _ = try decodeAPIResponse(
            CloudflareEmptyPayload.self,
            data: data,
            response: response,
            defaultFailureMessage: "Failed to delete DNS record.",
            requireResult: false
        )
    }

    public static func pushTunnelConfiguration(
        settings: CloudflareSettings,
        routes: [TunnelRoute],
        sites: [Site],
        projects: [AppProject],
        session: URLSession = defaultSession
    ) async throws {
        guard settings.hasLocalConfiguration else {
            throw CloudflareServiceError.missingLocalConfiguration
        }
        try requireAPI(settings, zone: false, tunnel: true)

        let renderer = TunnelConfigRenderer(settings: settings)
        let issues = renderer.validationIssues(routes: routes, sites: sites, projects: projects)
        guard issues.isEmpty else {
            throw CloudflareServiceError.invalidTunnelConfiguration(issues)
        }

        let resolvedRoutes = renderer.resolvedRoutes(routes: routes, sites: sites, projects: projects)
        let url = URL(string: "\(apiBase)/accounts/\(settings.accountId)/cfd_tunnel/\(settings.tunnelId)/configurations")!
        // Nest owns the ingress list, but WARP private-network routing is configured elsewhere: keep it.
        let warpRoutingEnabled = try await remoteWarpRoutingEnabled(url: url, settings: settings, session: session)
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
                warpRouting: .init(enabled: warpRoutingEnabled)
            )
        )

        let request = apiRequest(url, method: "PUT", settings: settings, body: try JSONEncoder().encode(payload))
        let (data, response) = try await session.data(for: request)
        _ = try decodeAPIResponse(
            CloudflareEmptyPayload.self,
            data: data,
            response: response,
            defaultFailureMessage: "Failed to push tunnel configuration.",
            requireResult: false
        )
    }

    private static func remoteWarpRoutingEnabled(url: URL, settings: CloudflareSettings, session: URLSession) async throws -> Bool {
        let (data, response) = try await session.data(for: apiRequest(url, settings: settings))
        let remote = try decodeAPIResponse(
            CloudflareRemoteTunnelConfiguration.self,
            data: data,
            response: response,
            defaultFailureMessage: "Failed to read the current tunnel configuration.",
            requireResult: false
        )
        return remote?.config?.warpRouting?.enabled ?? false
    }
}
