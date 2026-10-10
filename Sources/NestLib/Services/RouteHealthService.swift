import Foundation

public enum RouteHealth: Equatable, Sendable {
    case checking, reachable(Int), httpError(Int), macDNS, dnsPending, failed(String)

    public var label: String {
        switch self {
        case .checking: return "Checking…"
        case .reachable(let status): return "Reachable • HTTP \(status)"
        case .httpError(let status): return "HTTP \(status) • check the site or tunnel"
        case .macDNS: return "Public DNS ready • Mac lookup failed"
        case .dnsPending: return "Waiting for public DNS • retry shortly"
        case .failed(let message): return message
        }
    }
}

/// Distinguish a missing public record from the stale macOS lookup that can survive
/// publication. A fresh URLSession avoids reusing an earlier connection or HTTP cache.
public struct RouteHealthService {
    public typealias Request = (URLRequest) async throws -> (Data, URLResponse)
    private let request: Request

    public init(request: @escaping Request = { request in
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }) { self.request = request }

    public func check(hostname: String) async -> RouteHealth {
        guard NestValidation.domainIssues(hostname, field: "Hostname").isEmpty,
              let url = URL(string: "https://\(hostname)/") else { return .failed("Invalid public hostname") }
        var probe = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        probe.httpMethod = "HEAD"
        do {
            let (_, response) = try await request(probe)
            guard let http = response as? HTTPURLResponse else { return .failed("Unexpected response") }
            return (200..<400).contains(http.statusCode) ? .reachable(http.statusCode) : .httpError(http.statusCode)
        } catch {
            let failure = error as NSError
            guard failure.domain == NSURLErrorDomain,
                  [URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue].contains(failure.code) else {
                return .failed("Unreachable: \(error.localizedDescription)")
            }
            // Only offer privileged cache recovery when public DNS has an address.
            do {
                for type in ["A", "AAAA"] {
                    var components = URLComponents(string: "https://cloudflare-dns.com/dns-query")!
                    components.queryItems = [URLQueryItem(name: "name", value: hostname), URLQueryItem(name: "type", value: type)]
                    var dns = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
                    dns.setValue("application/dns-json", forHTTPHeaderField: "Accept")
                    let (data, response) = try await request(dns)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        return .failed("Mac DNS lookup failed; public DNS could not be checked")
                    }
                    let result = try JSONDecoder().decode(DNSAnswer.self, from: data)
                    if result.Status == 0, result.Answer?.contains(where: { $0.type == 1 || $0.type == 28 }) == true { return .macDNS }
                    guard result.Status == 0 || result.Status == 3 else {
                        return .failed("Public DNS returned an error; retry shortly")
                    }
                }
                return .dnsPending
            } catch { return .failed("Mac DNS lookup failed; public DNS could not be checked") }
        }
    }

    private struct DNSAnswer: Decodable {
        var Status: Int
        var Answer: [Record]?
        struct Record: Decodable { var type: Int }
    }

    public static func refreshMacDNS() async throws {
        // Fixed command, with no user input interpolated into AppleScript or the shell.
        let result = await SystemProcess.captureAsync("/usr/bin/osascript", arguments: ["-e",
            "do shell script \"/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder\" with administrator privileges"], timeout: 120)
        guard result.status == 0 else {
            if result.output.contains("-128") { throw ConfigurationFailure("DNS refresh cancelled. You can retry when ready.") }
            throw ConfigurationFailure("Could not refresh Mac DNS: \(result.output)")
        }
    }
}
