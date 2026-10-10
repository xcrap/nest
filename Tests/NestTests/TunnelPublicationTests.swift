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
        let cf = CloudflareSettings(apiToken: "fixture-token", zoneId: "fixture-zone", accountId: "fixture-account", tunnelId: "fixture-id",
            tunnelName: "fixture", tunnelDomain: "fixture.cfargotunnel.com", configPath: "/tmp/fixture.yaml", credentialsFilePath: "/tmp/fixture.json")
        let existing = #"{"success":true,"errors":[],"result":[{"id":"record","name":"new.example.com","type":"CNAME","content":"fixture.cfargotunnel.com","proxied":true,"ttl":1}]}"#
        TunnelDNSProtocol.configure { _ in (200, existing) }
        do {
            try await CloudflareService.ensureTunnelDNS(hostname: "new.example.com", settings: cf, session: session)
            check(TunnelDNSProtocol.methods == ["GET"], "matching DNS is reused without writes")
            check(TunnelDNSProtocol.names == ["new.example.com"], "DNS lookup is scoped to the exact hostname")
        } catch { check(false, "existing DNS: \(error)") }
        TunnelDNSProtocol.configure { request in
            (200, request.httpMethod == "POST" ? #"{"success":true,"errors":[],"result":{}}"# : #"{"success":true,"errors":[],"result":[]}"#)
        }
        do {
            try await CloudflareService.ensureTunnelDNS(hostname: "new.example.com", settings: cf, session: session)
            check(TunnelDNSProtocol.methods == ["GET", "POST"], "missing DNS is created once")
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

private final class TunnelDNSProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, String))?
    private static var requests: [URLRequest] = []
    static func configure(_ handler: @escaping (URLRequest) -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler; requests = []
    }
    static var methods: [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.map { $0.httpMethod ?? "GET" }
    }
    static var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "name" })?.value }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        let (status, body) = handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
