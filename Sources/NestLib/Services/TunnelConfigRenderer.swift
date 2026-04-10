import Foundation

public struct ResolvedTunnelRoute: Equatable {
    public var hostname: String
    public var service: String
    public var httpHostHeader: String
    public var noTLSVerify: Bool

    public init(hostname: String, service: String, httpHostHeader: String, noTLSVerify: Bool) {
        self.hostname = hostname
        self.service = service
        self.httpHostHeader = httpHostHeader
        self.noTLSVerify = noTLSVerify
    }
}

public struct TunnelConfigRenderer {
    public let settings: CloudflareSettings

    public init(settings: CloudflareSettings) {
        self.settings = settings
    }

    public func resolvedRoutes(
        routes: [TunnelRoute],
        sites: [Site],
        projects: [AppProject]
    ) -> [ResolvedTunnelRoute] {
        routes
            .filter(\.active)
            .compactMap { route in
                switch route.kind {
                case .php:
                    let localDomain = sites.first(where: { $0.domain == route.linkedSiteDomain })?.domain ?? route.localDomain
                    guard !localDomain.isEmpty else { return nil }
                    let port = route.originPort > 0 ? route.originPort : 443
                    return ResolvedTunnelRoute(
                        hostname: route.publicHostname,
                        service: "https://localhost:\(port)",
                        httpHostHeader: localDomain,
                        noTLSVerify: true
                    )
                case .app:
                    let linkedProject = projects.first(where: { $0.id == route.linkedProjectID })
                    let hostHeader = linkedProject?.hostname ?? route.localDomain
                    let port = linkedProject?.port ?? route.originPort
                    guard !hostHeader.isEmpty, port > 0 else { return nil }
                    return ResolvedTunnelRoute(
                        hostname: route.publicHostname,
                        service: "http://localhost:\(port)",
                        httpHostHeader: hostHeader,
                        noTLSVerify: false
                    )
                }
            }
            .sorted { $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending }
    }

    public func render(
        routes: [TunnelRoute],
        sites: [Site],
        projects: [AppProject]
    ) -> String {
        var lines: [String] = []
        lines.append("tunnel: \(settings.tunnelName)")
        lines.append("credentials-file: \(settings.credentialsFilePath)")
        lines.append("")
        lines.append("ingress:")

        for route in resolvedRoutes(routes: routes, sites: sites, projects: projects) {
            lines.append("  - hostname: \(route.hostname)")
            lines.append("    service: \(route.service)")
            lines.append("    originRequest:")
            if route.noTLSVerify {
                lines.append("      noTLSVerify: true")
            }
            lines.append("      httpHostHeader: \(route.httpHostHeader)")
            lines.append("")
        }

        lines.append("  - service: http_status:404")
        return lines.joined(separator: "\n")
    }

    public func writeConfig(
        routes: [TunnelRoute],
        sites: [Site],
        projects: [AppProject]
    ) throws {
        let path = settings.configPath
        let parentDirectory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parentDirectory, withIntermediateDirectories: true)
        try render(routes: routes, sites: sites, projects: projects).write(
            toFile: path,
            atomically: true,
            encoding: .utf8
        )
    }
}
