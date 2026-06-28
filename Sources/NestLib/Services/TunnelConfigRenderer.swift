import Foundation

public enum TunnelConfigRendererError: LocalizedError, Equatable {
    case invalidConfiguration([String])

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let issues):
            "Cannot write cloudflared config: \(issues.joined(separator: " "))"
        }
    }
}

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

    public func validationIssues(
        routes: [TunnelRoute],
        sites: [Site],
        projects: [AppProject]
    ) -> [String] {
        var issues = NestValidation.cloudflareSettingsIssues(settings)
        let activeRoutes = routes.filter(\.active)
        let resolved = resolvedRoutes(routes: routes, sites: sites, projects: projects)
        let resolvedHosts = Set(resolved.map(\.hostname))

        for route in activeRoutes {
            for issue in NestValidation.tunnelRouteIssues(route) {
                issues.append("\(route.publicHostname): \(issue)")
            }

            if !resolvedHosts.contains(route.publicHostname) {
                issues.append("\(route.publicHostname): Route has no resolvable local origin.")
            }
        }

        for route in resolved {
            issues.append(contentsOf: NestValidation.domainIssues(route.hostname, field: "\(route.hostname) public hostname"))
            issues.append(contentsOf: NestValidation.domainIssues(route.httpHostHeader, field: "\(route.hostname) host header"))

            if NestValidation.containsControlCharacters(route.service) {
                issues.append("\(route.hostname): Service cannot contain control characters.")
            }
        }

        return issues
    }

    public func render(
        routes: [TunnelRoute],
        sites: [Site],
        projects: [AppProject]
    ) -> String {
        var lines: [String] = []
        lines.append("tunnel: \(NestValidation.yamlScalar(settings.tunnelName))")
        lines.append("credentials-file: \(NestValidation.yamlScalar(settings.credentialsFilePath))")
        lines.append("")
        lines.append("ingress:")

        for route in resolvedRoutes(routes: routes, sites: sites, projects: projects) {
            lines.append("  - hostname: \(NestValidation.yamlScalar(route.hostname))")
            lines.append("    service: \(NestValidation.yamlScalar(route.service))")
            lines.append("    originRequest:")
            if route.noTLSVerify {
                lines.append("      noTLSVerify: true")
            }
            lines.append("      httpHostHeader: \(NestValidation.yamlScalar(route.httpHostHeader))")
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
        let issues = validationIssues(routes: routes, sites: sites, projects: projects)
        guard issues.isEmpty else {
            throw TunnelConfigRendererError.invalidConfiguration(issues)
        }

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
