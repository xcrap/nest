import Foundation

public enum ConfigRendererError: LocalizedError, Equatable {
    case invalidConfiguration([String])

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let issues):
            "Cannot write FrankenPHP config: \(issues.joined(separator: " "))"
        }
    }
}

/// Generates and writes FrankenPHP/Caddy configuration from stored sites and from projects
/// that have a local `.test` domain.
public struct ConfigRenderer {
    public let configDirectory: String
    public let frankenphpLogPath: String

    public init(configDirectory: String, frankenphpLogPath: String) {
        self.configDirectory = configDirectory
        self.frankenphpLogPath = frankenphpLogPath
    }

    public var caddyfilePath: String {
        (configDirectory as NSString).appendingPathComponent("Caddyfile")
    }

    public var securityConfPath: String {
        (configDirectory as NSString).appendingPathComponent("security.conf")
    }

    public var snippetsDirectory: String {
        (configDirectory as NSString).appendingPathComponent("snippets")
    }

    // MARK: - Caddyfile Generation

    public func validationIssues(sites: [Site], projects: [AppProject]) -> [String] {
        var issues: [String] = []
        issues.append(contentsOf: NestValidation.absolutePathIssues(configDirectory, field: "Caddy config directory"))
        issues.append(contentsOf: NestValidation.caddyPathIssues(configDirectory, field: "Caddy config directory"))

        if !frankenphpLogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(contentsOf: NestValidation.absolutePathIssues(frankenphpLogPath, field: "FrankenPHP log path"))
            issues.append(contentsOf: NestValidation.caddyPathIssues(frankenphpLogPath, field: "FrankenPHP log path"))
        }

        var runningSiteCounts: [String: Int] = [:]
        for site in sites where site.status == .running {
            for issue in NestValidation.siteIssues(site) {
                issues.append("\(site.domain): \(issue)")
            }
            runningSiteCounts[site.domain, default: 0] += 1
        }

        var projectNames: [String: [String]] = [:]
        for project in projects {
            guard let localDomain = project.localDomain else { continue }
            for issue in NestValidation.localDomainIssues(project) + NestValidation.portIssues(project.port, field: "Project port") {
                issues.append("\(localDomain): \(issue)")
            }
            projectNames[localDomain, default: []].append(project.name)
        }

        // Caddy refuses a config that defines the same site address twice.
        let addresses = Set(runningSiteCounts.keys).union(projectNames.keys)
        for domain in addresses.sorted() {
            let siteCount = runningSiteCounts[domain] ?? 0
            let names = projectNames[domain] ?? []
            guard siteCount + names.count > 1 else { continue }
            if names.isEmpty {
                issues.append("\(domain): \(siteCount) running sites use this domain; stop all but one.")
            } else {
                let sitesPart = siteCount == 0 ? [] : [siteCount == 1 ? "a running site" : "\(siteCount) running sites"]
                let users = sitesPart + names.map { "the project '\($0)'" }
                // Joined by hand: ListFormatter follows the user's locale, and these messages are English.
                let list = users.count == 2 ? users.joined(separator: " and ") : users.dropLast().joined(separator: ", ") + ", and " + users[users.count - 1]
                issues.append("\(domain): \(list) use this domain; give each its own.")
            }
        }

        return issues
    }

    public func render(sites: [Site], projects: [AppProject]) -> String {
        var lines: [String] = []

        lines.append("{")
        lines.append("    http_port 8080")
        lines.append("    https_port 8443")
        lines.append("    admin localhost:2019")
        lines.append("    local_certs")
        if !frankenphpLogPath.isEmpty {
            lines.append("    log {")
            lines.append("        output file \(NestValidation.caddyfileArgument(frankenphpLogPath))")
            lines.append("        format console")
            lines.append("    }")
        }
        lines.append("}")
        lines.append("")
        lines.append("import \(NestValidation.caddyfileArgument(snippetsDirectory + "/*"))")
        lines.append("import \(NestValidation.caddyfileArgument(configDirectory + "/overrides/*.caddy"))")
        lines.append("")

        lines.append("localhost {")
        lines.append("    tls internal")
        lines.append("    respond 204")
        lines.append("}")
        lines.append("")

        let runningSites = sites.filter { $0.status == .running }
        for site in runningSites {
            lines.append(
                "import php-app \(NestValidation.caddyfileArgument(site.domain)) \(NestValidation.caddyfileArgument(site.rootPath)) \(NestValidation.caddyfileArgument(site.resolvedDocumentRoot))"
            )
        }

        if !runningSites.isEmpty {
            lines.append("")
        }

        // A project is proxied whether or not it runs: a stopped one answers 502 instead of
        // a certificate or DNS error, and starting or stopping it never reloads Caddy.
        // security.conf is left out on purpose: its X-Frame-Options DENY would block the
        // same-origin iframes dev tools use (Storybook, Nuxt DevTools).
        for project in projects {
            guard let localDomain = project.localDomain else { continue }
            lines.append("\(localDomain) {")
            lines.append("    tls internal")
            lines.append("    reverse_proxy 127.0.0.1:\(project.port) {")
            // Dev servers (Vite, webpack, Angular) refuse unknown Host headers; the app can still
            // read the original host from X-Forwarded-Host, which Caddy sets.
            lines.append("        header_up Host {upstream_hostport}")
            lines.append("    }")
            lines.append("}")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    public var phpAppSnippet: String {
        """
        (php-app) {
            {args[0]} {
                import \(NestValidation.caddyfileArgument(securityConfPath))
                root * {args[2]}
                @blocked path */.* *.sql *.log *.bak *.env
                respond @blocked 404
                encode zstd gzip
                php_server
                file_server
            }
        }
        """
    }

    public var securityConf: String {
        """
        header {
            Referrer-Policy "strict-origin-when-cross-origin"
            Strict-Transport-Security "max-age=31536000; includeSubDomains"
            X-Content-Type-Options "nosniff"
            X-Frame-Options "DENY"
        }
        """
    }

    // MARK: - Write Config Files

    public func writeAll(sites: [Site], projects: [AppProject]) throws {
        let issues = validationIssues(sites: sites, projects: projects)
        guard issues.isEmpty else {
            throw ConfigRendererError.invalidConfiguration(issues)
        }

        try writeSupportFiles()
        let caddyfile = render(sites: sites, projects: projects)
        try caddyfile.write(toFile: caddyfilePath, atomically: true, encoding: .utf8)
    }

    public func writeSupportFiles() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: configDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: snippetsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: configDirectory + "/overrides", withIntermediateDirectories: true)

        if !fm.fileExists(atPath: securityConfPath) {
            try securityConf.write(toFile: securityConfPath, atomically: true, encoding: .utf8)
        }

        let snippetPath = (snippetsDirectory as NSString).appendingPathComponent("php-app")
        if !fm.fileExists(atPath: snippetPath) {
            try phpAppSnippet.write(toFile: snippetPath, atomically: true, encoding: .utf8)
        }

    }
}
