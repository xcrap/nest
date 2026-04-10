import Foundation

public struct MindImportPayload {
    public var sourceDirectory: URL
    public var cloudflareSettings: CloudflareSettings
    public var projects: [AppProject]
    public var tunnelRoutes: [TunnelRoute]
    public var warnings: [String]

    public init(
        sourceDirectory: URL,
        cloudflareSettings: CloudflareSettings,
        projects: [AppProject],
        tunnelRoutes: [TunnelRoute],
        warnings: [String]
    ) {
        self.sourceDirectory = sourceDirectory
        self.cloudflareSettings = cloudflareSettings
        self.projects = projects
        self.tunnelRoutes = tunnelRoutes
        self.warnings = warnings
    }
}

public struct MindImportSummary {
    public var importedProjects: Int
    public var importedRoutes: Int
    public var warnings: [String]

    public init(importedProjects: Int, importedRoutes: Int, warnings: [String]) {
        self.importedProjects = importedProjects
        self.importedRoutes = importedRoutes
        self.warnings = warnings
    }

    public var message: String {
        var lines = [
            "Imported \(importedProjects) project(s).",
            "Imported \(importedRoutes) tunnel route(s)."
        ]

        if !warnings.isEmpty {
            lines.append("")
            lines.append("Warnings:")
            lines.append(contentsOf: warnings)
        }

        return lines.joined(separator: "\n")
    }
}

public struct CloudflaredConfigSnapshot: Equatable {
    public var tunnelName: String
    public var credentialsFilePath: String
    public var routes: [TunnelRoute]
    public var warnings: [String]

    public init(tunnelName: String, credentialsFilePath: String, routes: [TunnelRoute], warnings: [String]) {
        self.tunnelName = tunnelName
        self.credentialsFilePath = credentialsFilePath
        self.routes = routes
        self.warnings = warnings
    }
}

public enum MindImportServiceError: LocalizedError {
    case directoryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .directoryNotFound(let path):
            return "Mind directory not found at \(path)"
        }
    }
}

private struct MindSitesFile: Decodable {
    var sites: [TunnelRoute]
}

private struct MindCloudflareFile: Decodable {
    var apiToken: String
    var zoneId: String
    var accountId: String
    var tunnelId: String
    var tunnelDomain: String
}

public enum MindImportService {
    public static func buildPayload(
        from directory: URL,
        existingSites: [Site],
        currentSettings: AppSettings
    ) throws -> MindImportPayload {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw MindImportServiceError.directoryNotFound(directory.path)
        }

        let dataDirectory = directory.appendingPathComponent("data")
        let projects = loadProjects(at: dataDirectory.appendingPathComponent("projects.json"))
        let mindRoutes = loadRoutes(at: dataDirectory.appendingPathComponent("sites.json"))
        let cloudflareFile = loadCloudflareSettings(at: dataDirectory.appendingPathComponent("cloudflare.json"))

        let liveConfigPath = currentSettings.cloudflareSettings.configPath.isEmpty
            ? CloudflareSettings.detectDefaults().configPath
            : currentSettings.cloudflareSettings.configPath
        let liveSnapshot = loadLiveSnapshot(configPath: liveConfigPath)

        var settings = currentSettings.cloudflareSettings
        if let cloudflareFile {
            settings.apiToken = cloudflareFile.apiToken
            settings.zoneId = cloudflareFile.zoneId
            settings.accountId = cloudflareFile.accountId
            settings.tunnelId = cloudflareFile.tunnelId
            settings.tunnelDomain = cloudflareFile.tunnelDomain
        }

        if !liveSnapshot.tunnelName.isEmpty {
            settings.tunnelName = liveSnapshot.tunnelName
        }
        if !liveSnapshot.credentialsFilePath.isEmpty {
            settings.credentialsFilePath = liveSnapshot.credentialsFilePath
        }
        if settings.configPath.isEmpty {
            settings.configPath = liveConfigPath
        }
        if settings.tunnelId.isEmpty, !settings.credentialsFilePath.isEmpty {
            settings.tunnelId = URL(fileURLWithPath: settings.credentialsFilePath).deletingPathExtension().lastPathComponent
        }
        if settings.tunnelDomain.isEmpty, !settings.tunnelId.isEmpty {
            settings.tunnelDomain = "\(settings.tunnelId).cfargotunnel.com"
        }

        var warnings = liveSnapshot.warnings
        var routeMap: [String: TunnelRoute] = Dictionary(
            uniqueKeysWithValues: liveSnapshot.routes.map { ($0.publicHostname, $0) }
        )

        for route in mindRoutes {
            var merged = route
            if let live = routeMap[route.publicHostname] {
                merged.active = live.active || route.active
            }

            if merged.kind == .php,
               let site = existingSites.first(where: {
                   $0.domain == merged.localDomain
                   || $0.domain == merged.linkedSiteDomain
                   || $0.domain == "\(merged.localDomain).test"
               }) {
                merged.linkedSiteDomain = site.domain
            }

            if merged.kind == .app,
               let project = projects.first(where: { $0.hostname == merged.localDomain || $0.hostname == merged.publicHostname }) {
                merged.linkedProjectID = project.id
            }

            routeMap[merged.publicHostname] = merged
        }

        for hostname in routeMap.keys.sorted() {
            if routeMap[hostname]?.kind == .php,
               routeMap[hostname]?.linkedSiteDomain == nil,
               let route = routeMap[hostname],
               let site = existingSites.first(where: { $0.domain == route.localDomain || $0.domain == "\(route.localDomain).test" }) {
                var linked = route
                linked.linkedSiteDomain = site.domain
                routeMap[hostname] = linked
            }
        }

        if liveSnapshot.routes.isEmpty, mindRoutes.isEmpty {
            warnings.append("No tunnel routes were found in Mind or the live cloudflared config.")
        }

        return MindImportPayload(
            sourceDirectory: directory,
            cloudflareSettings: settings,
            projects: projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            tunnelRoutes: routeMap.values.sorted { $0.publicHostname.localizedCaseInsensitiveCompare($1.publicHostname) == .orderedAscending },
            warnings: warnings
        )
    }

    public static func parseConfigString(_ content: String, configPath: String) -> CloudflaredConfigSnapshot {
        var tunnelName = ""
        var credentialsFilePath = ""
        var warnings: [String] = []
        var routes: [TunnelRoute] = []

        var currentHostname: String?
        var currentService: String?
        var currentHostHeader = ""
        var currentNoTLSVerify = false

        func finalizeCurrentRoute() {
            guard let hostname = currentHostname, let service = currentService else { return }
            defer {
                currentHostname = nil
                currentService = nil
                currentHostHeader = ""
                currentNoTLSVerify = false
            }

            if service == "http_status:404" {
                return
            }

            let routeKind: TunnelRouteKind
            let originPort: Int

            if service.hasPrefix("https://localhost:") {
                routeKind = .php
                originPort = Int(service.replacingOccurrences(of: "https://localhost:", with: "")) ?? 443
            } else if service.hasPrefix("http://localhost:") {
                routeKind = .app
                originPort = Int(service.replacingOccurrences(of: "http://localhost:", with: "")) ?? 0
            } else {
                warnings.append("Skipped unsupported live cloudflared route for \(hostname).")
                return
            }

            let (subdomain, publicDomain) = splitHostname(hostname)
            routes.append(
                TunnelRoute(
                    id: TunnelRoute.defaultID(from: hostname),
                    kind: routeKind,
                    subdomain: subdomain,
                    publicDomain: publicDomain,
                    localDomain: currentHostHeader.isEmpty ? hostname : currentHostHeader,
                    originPort: originPort,
                    active: true,
                    linkedSiteDomain: nil,
                    linkedProjectID: nil
                )
            )
        }

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("tunnel:") {
                tunnelName = line.replacingOccurrences(of: "tunnel:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("credentials-file:") {
                credentialsFilePath = line.replacingOccurrences(of: "credentials-file:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- hostname:") || line.hasPrefix("-hostname:") {
                finalizeCurrentRoute()
                currentHostname = line
                    .replacingOccurrences(of: "- hostname:", with: "")
                    .replacingOccurrences(of: "-hostname:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("service:") {
                currentService = line.replacingOccurrences(of: "service:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- service:") {
                finalizeCurrentRoute()
                currentService = line.replacingOccurrences(of: "- service:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("httpHostHeader:") {
                currentHostHeader = line.replacingOccurrences(of: "httpHostHeader:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("noTLSVerify:") {
                currentNoTLSVerify = line.replacingOccurrences(of: "noTLSVerify:", with: "").trimmingCharacters(in: .whitespaces) == "true"
            }
        }

        finalizeCurrentRoute()

        if currentNoTLSVerify, routes.isEmpty {
            warnings.append("Live cloudflared config at \(configPath) contains unsupported tunnel options.")
        }

        return CloudflaredConfigSnapshot(
            tunnelName: tunnelName,
            credentialsFilePath: credentialsFilePath,
            routes: routes,
            warnings: warnings
        )
    }

    private static func loadProjects(at url: URL) -> [AppProject] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AppProject].self, from: data)) ?? []
    }

    private static func loadRoutes(at url: URL) -> [TunnelRoute] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode(MindSitesFile.self, from: data).sites) ?? []
    }

    private static func loadCloudflareSettings(at url: URL) -> MindCloudflareFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MindCloudflareFile.self, from: data)
    }

    private static func loadLiveSnapshot(configPath: String) -> CloudflaredConfigSnapshot {
        guard !configPath.isEmpty,
              let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return CloudflaredConfigSnapshot(tunnelName: "", credentialsFilePath: "", routes: [], warnings: [])
        }

        return parseConfigString(content, configPath: configPath)
    }

    private static func splitHostname(_ hostname: String) -> (String, String) {
        let components = hostname.split(separator: ".", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return (hostname, "") }
        let subdomain = String(components.first ?? "")
        let publicDomain = components.dropFirst().joined(separator: ".")
        return (subdomain, publicDomain)
    }
}
