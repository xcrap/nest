import Foundation
import NestLib

@MainActor
enum TunnelPublicationTests {
    static func runAll() async -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ value: Bool, _ message: String) {
            if value { passed += 1 } else { failed += 1; print("  FAIL: \(message)") }
        }
        func response(_ request: URLRequest, _ status: Int = 200) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        let reachable = RouteHealthService { request in (Data(), response(request)) }
        check(await reachable.check(hostname: "example.com") == .reachable(200), "successful HTTPS is reachable")
        let serverError = RouteHealthService { request in (Data(), response(request, 502)) }
        check(await serverError.check(hostname: "example.com") == .httpError(502), "origin errors are not DNS failures")
        let certificateError = RouteHealthService { _ in throw URLError(.serverCertificateUntrusted) }
        if case .failed = await certificateError.check(hostname: "example.com") { check(true, "TLS failure is preserved") }
        else { check(false, "TLS failure is preserved") }
        for (json, expected) in [
            (#"{"Status":0,"Answer":[{"type":1}]}"#, RouteHealth.macDNS),
            (#"{"Status":0,"Answer":[{"type":28}]}"#, .macDNS),
            (#"{"Status":3}"#, .dnsPending),
            (#"{"Status":0,"Answer":[{"type":5}]}"#, .dnsPending)
        ] {
            let probe = RouteHealthService { request in
                if request.url?.host == "example.com" { throw URLError(.cannotFindHost) }
                return (Data(json.utf8), response(request))
            }
            check(await probe.check(hostname: "example.com") == expected, "DNS classification: \(json)")
        }
        let dnsError = RouteHealthService { request in
            if request.url?.host == "example.com" { throw URLError(.dnsLookupFailed) }
            return (Data(#"{"Status":2}"#.utf8), response(request))
        }
        if case .failed = await dnsError.check(hostname: "example.com") { check(true, "SERVFAIL is not a stale Mac cache") }
        else { check(false, "SERVFAIL is not a stale Mac cache") }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TunnelDNSProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let cf = CloudflareSettings(apiToken: "fixture-token", zoneId: "0123456789abcdef0123456789abcdef", accountId: "fedcba9876543210fedcba9876543210",
            tunnelId: "6ff42ae2-765d-4adf-8112-31c55c1551ef",
            tunnelName: "fixture", tunnelDomain: "fixture.cfargotunnel.com", configPath: "/tmp/fixture.yaml", credentialsFilePath: "/tmp/fixture.json")
        let existing = #"{"success":true,"errors":[],"result":[{"id":"record","name":"new.example.com","type":"CNAME","content":"fixture.cfargotunnel.com","proxied":true,"ttl":1}]}"#
        TunnelDNSProtocol.configure { _ in (200, existing) }
        do {
            try await CloudflareService.ensureTunnelDNS(hostname: "new.example.com", settings: cf, session: session)
            check(TunnelDNSProtocol.methods == ["GET"], "matching DNS is reused without writes")
            check(TunnelDNSProtocol.names == ["new.example.com"], "DNS lookup is scoped to the exact hostname")
            check(TunnelDNSProtocol.zoneLookups == 1, "the zone name is looked up before DNS changes")
        } catch { check(false, "existing DNS: \(error)") }
        TunnelDNSProtocol.configure { request in
            (200, request.httpMethod == "POST" ? #"{"success":true,"errors":[],"result":{}}"# : #"{"success":true,"errors":[],"result":[]}"#)
        }
        do {
            try await CloudflareService.ensureTunnelDNS(hostname: "new.example.com", settings: cf, session: session)
            check(TunnelDNSProtocol.methods == ["GET", "POST"], "missing DNS is created once")
            check(TunnelDNSProtocol.zoneLookups == 0, "the zone name is cached per zone ID")
            check(TunnelDNSProtocol.requests.allSatisfy { $0.timeoutInterval == CloudflareService.requestTimeout },
                  "Cloudflare requests use the short timeout")
        } catch { check(false, "new DNS: \(error)") }
        for conflicting in [existing.replacingOccurrences(of: "fixture.cfargotunnel.com", with: "other.example.com"), existing.replacingOccurrences(of: "true,\"ttl", with: "false,\"ttl")] {
            TunnelDNSProtocol.configure { _ in (200, conflicting) }
            do {
                try await CloudflareService.ensureTunnelDNS(hostname: "new.example.com", settings: cf, session: session)
                check(false, "DNS conflict must fail")
            } catch { check(TunnelDNSProtocol.methods == ["GET"] && error.localizedDescription.contains("unchanged"), "conflicting DNS is protected") }
        }
        TunnelDNSProtocol.configure { _ in (403, #"{"success":false,"errors":[{"message":"denied"}],"result":null}"#) }
        do {
            try await CloudflareService.ensureTunnelDNS(hostname: "new.example.com", settings: cf, session: session)
            check(false, "DNS permission failure must throw")
        } catch { check(error.localizedDescription.contains("403") && TunnelDNSProtocol.methods == ["GET"], "failed DNS lookup never creates a record") }

        // Hostnames outside the zone would be created relative to it (app.other.org.example.com).
        TunnelDNSProtocol.configure { _ in (200, #"{"success":true,"errors":[],"result":[]}"#) }
        do {
            try await CloudflareService.ensureTunnelDNS(hostname: "app.other.org", settings: cf, session: session)
            check(false, "out-of-zone hostname must fail")
        } catch {
            check(TunnelDNSProtocol.methods.isEmpty && error.localizedDescription.contains("outside the Cloudflare zone example.com"),
                  "out-of-zone hostnames are refused before any DNS request")
        }
        check(CloudflareService.isHostname("example.com", inZone: "example.com"), "zone apex is in the zone")
        check(CloudflareService.isHostname("A.Example.com.", inZone: "example.com"), "zone check ignores case and trailing dot")
        check(!CloudflareService.isHostname("badexample.com", inZone: "example.com"), "a suffix that is not a label boundary is outside the zone")
        check(CloudflareService.zoneIssue(hostname: "x.other.org", zone: "example.com")?.contains("x.other.org") == true, "zone issue names the hostname")
        check(CloudflareService.zoneIssue(hostname: "x.example.com", zone: "example.com") == nil, "in-zone hostnames have no zone issue")
        check(CloudflareService.cachedZoneName(zoneId: cf.zoneId.uppercased()) == "example.com", "cached zone name is available to forms")

        // IDs are validated before they are interpolated into URLs.
        check(CloudflareService.isValidHexIdentifier("0123456789ABCDEF0123456789abcdef"), "32 hex characters are a valid ID")
        check(!CloudflareService.isValidHexIdentifier("fixture-zone"), "non-hex zone IDs are rejected")
        check(!CloudflareService.isValidHexIdentifier("0123456789abcdef0123456789abcde/"), "path characters are rejected")
        check(CloudflareService.isValidTunnelIdentifier("6ff42ae2-765d-4adf-8112-31c55c1551ef"), "tunnel UUIDs are valid")
        check(CloudflareService.isValidTunnelIdentifier("6ff42ae2765d4adf811231c55c1551ef"), "undashed tunnel IDs are valid")
        check(!CloudflareService.isValidTunnelIdentifier("6ff42ae2-765d-4adf-8112-31c55c1551e/"), "malformed tunnel IDs are rejected")
        check(CloudflareService.identifierIssues(cf).isEmpty, "valid fixture IDs have no issues")
        var badZone = cf
        badZone.zoneId = "zone/../../accounts"
        var badAccount = cf
        badAccount.accountId = "account"
        var badTunnel = cf
        badTunnel.tunnelId = "id?x=1"
        for (field, broken) in [("Zone ID", badZone), ("Account ID", badAccount), ("Tunnel ID", badTunnel)] {
            TunnelDNSProtocol.configure { _ in (200, #"{"success":true,"errors":[],"result":[]}"#) }
            do {
                try await CloudflareService.publishTunnel(settings: broken, routes: [], sites: [], projects: [], session: session)
                check(false, "invalid \(field) must fail")
            } catch {
                check(TunnelDNSProtocol.requests.isEmpty && TunnelDNSProtocol.zoneLookups == 0 && error.localizedDescription.contains(field),
                      "invalid \(field) fails before any request")
            }
        }
        do {
            _ = try await CloudflareService.listDNSRecords(settings: badZone, session: session)
            check(false, "listing with an invalid zone ID must fail")
        } catch { check(TunnelDNSProtocol.requests.isEmpty, "listing validates the zone ID") }
        do {
            try await CloudflareService.deleteDNSRecord(id: "../zones", settings: cf, session: session)
            check(false, "invalid record IDs must fail")
        } catch { check(TunnelDNSProtocol.requests.isEmpty, "record IDs are validated before deleting") }

        // Listing follows result_info pagination.
        TunnelDNSProtocol.configure { request in
            let page = TunnelDNSProtocol.query(request, "page") ?? "1"
            let name = page == "1" ? "a.example.com" : "b.example.com"
            return (200, #"{"success":true,"errors":[],"result":[{"id":"r\#(page)","name":"\#(name)","type":"CNAME","content":"fixture.cfargotunnel.com","proxied":true,"ttl":1}],"result_info":{"page":\#(page),"total_pages":2}}"#)
        }
        do {
            let records = try await CloudflareService.listDNSRecords(settings: cf, session: session)
            check(records.map(\.name) == ["a.example.com", "b.example.com"], "records from every page are returned")
            check(TunnelDNSProtocol.requests.compactMap { TunnelDNSProtocol.query($0, "page") } == ["1", "2"], "each page is requested once")
            check(TunnelDNSProtocol.requests.allSatisfy { TunnelDNSProtocol.query($0, "content") == "fixture.cfargotunnel.com" },
                  "listing is filtered to the tunnel")
        } catch { check(false, "pagination: \(error)") }

        // One bad route never blocks the others: the ingress is pushed and failures are listed.
        let publishRoutes = [
            TunnelRoute(id: "listed", kind: .php, subdomain: "listed", publicDomain: "example.com", localDomain: "a.test", originPort: 443),
            TunnelRoute(id: "new", kind: .php, subdomain: "new", publicDomain: "example.com", localDomain: "b.test", originPort: 443),
            TunnelRoute(id: "taken", kind: .php, subdomain: "taken", publicDomain: "example.com", localDomain: "c.test", originPort: 443),
            TunnelRoute(id: "foreign", kind: .php, subdomain: "app", publicDomain: "other.org", localDomain: "d.test", originPort: 443),
            TunnelRoute(id: "off", kind: .php, subdomain: "off", publicDomain: "example.com", localDomain: "e.test", originPort: 443, active: false)
        ]
        let ok = #"{"success":true,"errors":[],"result":{}}"#
        let listed = #"{"success":true,"errors":[],"result":[{"id":"l","name":"listed.example.com","type":"CNAME","content":"fixture.cfargotunnel.com","proxied":true,"ttl":1}],"result_info":{"page":1,"total_pages":1}}"#
        let taken = #"{"success":true,"errors":[],"result":[{"id":"t","name":"taken.example.com","type":"A","content":"192.0.2.1","proxied":false,"ttl":1}]}"#
        TunnelDNSProtocol.configure { request in
            if request.url!.path.hasSuffix("/configurations") || request.httpMethod == "POST" { return (200, ok) }
            if TunnelDNSProtocol.query(request, "content") != nil { return (200, listed) }
            if TunnelDNSProtocol.query(request, "name") == "taken.example.com" { return (200, taken) }
            return (200, #"{"success":true,"errors":[],"result":[]}"#)
        }
        do {
            try await CloudflareService.publishTunnel(settings: cf, routes: publishRoutes, sites: [], projects: [], session: session)
            check(false, "partial DNS failure must still throw")
        } catch {
            let message = error.localizedDescription
            check(message.contains("taken.example.com") && message.contains("app.other.org") && message.contains("2 hostnames"),
                  "every failed hostname is reported together")
            check(!message.contains("new.example.com") && !message.contains("listed.example.com"), "ready hostnames are not reported as failures")
            let pushes = TunnelDNSProtocol.requests.filter { $0.httpMethod == "PUT" }
            check(pushes.count == 1, "ingress is pushed despite DNS failures")
            let ingress = pushes.first.flatMap(TunnelDNSProtocol.body).map { String(decoding: $0, as: UTF8.self) } ?? ""
            check(ingress.contains("new.example.com") && ingress.contains("taken.example.com") && !ingress.contains("off.example.com"),
                  "pushed ingress has every active route and drops disabled ones")
            check(Set(TunnelDNSProtocol.names) == ["new.example.com", "taken.example.com"], "only hostnames missing from the listing are looked up by name")
            check(TunnelDNSProtocol.methods.filter { $0 == "POST" }.count == 1, "only the missing record is created")
        }

        // Many uncovered hostnames are all checked (a few at a time).
        let many = (1...9).map { TunnelRoute(id: "m\($0)", kind: .php, subdomain: "m\($0)", publicDomain: "example.com", localDomain: "m.test", originPort: 443) }
        TunnelDNSProtocol.configure { request in
            if request.url!.path.hasSuffix("/configurations") || request.httpMethod == "POST" { return (200, ok) }
            return (200, #"{"success":true,"errors":[],"result":[]}"#)
        }
        do {
            try await CloudflareService.publishTunnel(settings: cf, routes: many, sites: [], projects: [], session: session)
            check(Set(TunnelDNSProtocol.names) == Set(many.map(\.publicHostname)) && TunnelDNSProtocol.names.count == many.count,
                  "every uncovered hostname is looked up exactly once")
            check(TunnelDNSProtocol.methods.filter { $0 == "POST" }.count == many.count, "every missing record is created")
        } catch { check(false, "concurrent DNS: \(error)") }

        // An "Edit zone DNS" token may not read zone details: an unreadable zone skips only
        // the zone check, and DNS is created exactly as before.
        var unknownZone = cf
        unknownZone.zoneId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let unreadableZone: (URLRequest) -> (Int, String) = { request in
            if request.url!.path.hasSuffix("/zones/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") {
                return (403, #"{"success":false,"errors":[{"code":9109,"message":"Unauthorized"}],"result":null}"#)
            }
            if request.url!.path.hasSuffix("/configurations") || request.httpMethod == "POST" { return (200, ok) }
            return (200, #"{"success":true,"errors":[],"result":[]}"#)
        }
        TunnelDNSProtocol.configure(unreadableZone)
        do {
            try await CloudflareService.ensureTunnelDNS(hostname: "new.example.com", settings: unknownZone, session: session)
            check(TunnelDNSProtocol.zoneLookups == 1 && TunnelDNSProtocol.methods == ["GET", "POST"],
                  "a 403 zone lookup still creates the missing record")
            check(CloudflareService.cachedZoneName(zoneId: unknownZone.zoneId) == nil, "a failed zone lookup is not cached as a zone name")
        } catch { check(false, "unreadable zone must not block DNS: \(error)") }
        TunnelDNSProtocol.configure(unreadableZone)
        do {
            try await CloudflareService.publishTunnel(settings: unknownZone, routes: [publishRoutes[1], publishRoutes[3]], sites: [], projects: [], session: session)
            check(TunnelDNSProtocol.zoneLookups == 1, "publication tries the zone lookup once")
            check(Set(TunnelDNSProtocol.names) == ["new.example.com", "app.other.org"] && TunnelDNSProtocol.methods.filter { $0 == "POST" }.count == 2,
                  "without a known zone no hostname is refused and DNS is created as before")
            check(TunnelDNSProtocol.requests.filter { $0.httpMethod == "PUT" }.count == 1, "unreadable zone still publishes ingress")
        } catch { check(false, "unreadable zone must not fail publication: \(error)") }

        var settings = AppSettings()
        settings.cloudflareSettings = cf
        var route = TunnelRoute(id: "route", kind: .php, subdomain: "first", publicDomain: "example.com", localDomain: "example.test", originPort: 443, active: true)
        var published: [String] = []
        var publishFlags: [Bool] = []
        var resumeFirst: CheckedContinuation<Void, Never>?
        let controller = ProcessController(applyTunnel: { _, routes, _, _, _, push in
            published.append(routes[0].subdomain)
            publishFlags.append(push)
            if published.count == 1 { await withCheckedContinuation { resumeFirst = $0 } }
            return "Applied"
        }, probeRoute: { _ in .reachable(200) })
        controller.markTunnelsPending(settings: settings, routes: [route], sites: [], projects: [])
        check(published.isEmpty, "observing existing configuration never publishes on launch")
        route.subdomain = "second"
        controller.markTunnelsPending(settings: settings, routes: [route], sites: [], projects: [], automaticallyApply: true)
        for _ in 0..<100 where resumeFirst == nil { try? await Task.sleep(for: .milliseconds(5)) }
        route.subdomain = "third"
        controller.markTunnelsPending(settings: settings, routes: [route], sites: [], projects: [], automaticallyApply: true)
        route.subdomain = "latest"
        controller.markTunnelsPending(settings: settings, routes: [route], sites: [], projects: [], automaticallyApply: true)
        resumeFirst?.resume()
        for _ in 0..<100 where controller.isServiceBusy("Cloudflared") { try? await Task.sleep(for: .milliseconds(5)) }
        check(published == ["second", "latest"] && publishFlags == [true, true], "rapid saves serialize remote publication and keep newest change")
        try? await Task.sleep(for: .milliseconds(10))
        check(controller.routeHealth[route.id] == .reachable(200), "publication checks public reachability automatically")
        var unrelated = Site(name: "Unrelated", domain: "unrelated.test", rootPath: "/tmp", documentRoot: ".")
        unrelated.name = "Renamed"
        controller.markTunnelsPending(settings: settings, routes: [route], sites: [unrelated], projects: [], automaticallyApply: true)
        check(published.count == 2 && !controller.isServiceBusy("Cloudflared"), "unrelated site edits do not publish routes")

        let failure = ProcessController(applyTunnel: { _, _, _, _, _, _ in throw ConfigurationFailure("DNS is ready; API unavailable") })
        failure.applyTunnels(settings: settings, routes: [route], sites: [], projects: [], push: true)
        for _ in 0..<100 where failure.isServiceBusy("Cloudflared") { try? await Task.sleep(for: .milliseconds(5)) }
        check(failure.tunnelApplyState == .failed("DNS is ready; API unavailable"), "partial publication failure stays visible")

        var refreshed = 0
        var probeContinuation: CheckedContinuation<RouteHealth, Never>?
        let stale = ProcessController(probeRoute: { _ in await withCheckedContinuation { probeContinuation = $0 } })
        stale.checkRoute(route)
        for _ in 0..<100 where probeContinuation == nil { try? await Task.sleep(for: .milliseconds(5)) }
        stale.markTunnelsPending(settings: settings, routes: [], sites: [], projects: [])
        probeContinuation?.resume(returning: .macDNS)
        try? await Task.sleep(for: .milliseconds(10))
        check(stale.routeHealth.isEmpty, "deleted routes cannot receive stale health results")
        let recovery = ProcessController(probeRoute: { _ in refreshed == 0 ? .macDNS : .reachable(200) }, refreshDNS: { refreshed += 1 })
        recovery.checkRoute(route)
        try? await Task.sleep(for: .milliseconds(10))
        check(recovery.needsDNSRefresh, "Mac lookup failure exposes recovery")
        recovery.refreshMacDNS(routes: [route])
        recovery.refreshMacDNS(routes: [route])
        try? await Task.sleep(for: .milliseconds(10))
        check(refreshed == 1 && recovery.routeHealth[route.id] == .reachable(200), "one DNS refresh rechecks routes and clears recovery")
        let cancelled = ProcessController(refreshDNS: { throw ConfigurationFailure("DNS refresh cancelled") })
        cancelled.refreshMacDNS(routes: [route])
        try? await Task.sleep(for: .milliseconds(10))
        check(cancelled.dnsRefreshError == "DNS refresh cancelled" && !cancelled.refreshingDNS, "cancelled authorization remains retryable")
        return (passed, failed)
    }
}

/// Answers `GET /zones/{id}` with zone `example.com` unless the handler fails that request, and
/// keeps zone lookups out of `requests`, so DNS assertions only see the calls they are about.
private final class TunnelDNSProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, String))?
    private static var allRequests: [URLRequest] = []
    private static var zoneRequests = 0
    static func configure(_ handler: @escaping (URLRequest) -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler; allRequests = []; zoneRequests = 0
    }
    /// Every request except zone lookups.
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return allRequests.filter { !isZoneLookup($0) }
    }
    static var zoneLookups: Int {
        lock.lock(); defer { lock.unlock() }
        return zoneRequests
    }
    /// Methods of DNS record requests only.
    static var methods: [String] {
        requests.filter { $0.url!.path.contains("/dns_records") }.map { $0.httpMethod ?? "GET" }
    }
    static var names: [String] {
        requests.compactMap { query($0, "name") }
    }
    static func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value
    }
    static func body(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
    private static func isZoneLookup(_ request: URLRequest) -> Bool {
        request.url!.path.range(of: #"/zones/[^/]+$"#, options: .regularExpression) != nil
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.allRequests.append(request)
        let isZone = Self.isZoneLookup(request)
        if isZone { Self.zoneRequests += 1 }
        let handler = Self.handler
        Self.lock.unlock()
        var (status, body) = handler!(request)
        if isZone, status == 200 {
            (status, body) = (200, #"{"success":true,"errors":[],"result":{"id":"zone","name":"example.com"}}"#)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
