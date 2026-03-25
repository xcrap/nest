import Foundation

/// Generates and writes FrankenPHP/Caddy configuration from stored sites.
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

    public func render(sites: [Site]) -> String {
        var lines: [String] = []

        lines.append("{")
        lines.append("    http_port 8080")
        lines.append("    https_port 8443")
        lines.append("    admin localhost:2019")
        lines.append("    local_certs")
        if !frankenphpLogPath.isEmpty {
            lines.append("    log {")
            lines.append("        output file \"\(frankenphpLogPath)\"")
            lines.append("        format console")
            lines.append("    }")
        }
        lines.append("}")
        lines.append("")
        lines.append("import \(snippetsDirectory)/*")
        lines.append("")

        lines.append("localhost {")
        lines.append("    tls internal")
        lines.append("    respond 204")
        lines.append("}")
        lines.append("")

        let runningSites = sites.filter { $0.status == .running }
        for site in runningSites {
            lines.append("import php-app \(site.domain) \(site.rootPath) \(site.resolvedDocumentRoot)")
        }

        if !runningSites.isEmpty {
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    public var phpAppSnippet: String {
        """
        (php-app) {
            {args[0]} {
                import \(securityConfPath)
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

    public func writeAll(sites: [Site]) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: configDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: snippetsDirectory, withIntermediateDirectories: true)

        let caddyfile = render(sites: sites)
        try caddyfile.write(toFile: caddyfilePath, atomically: true, encoding: .utf8)
        try securityConf.write(toFile: securityConfPath, atomically: true, encoding: .utf8)

        let snippetPath = (snippetsDirectory as NSString).appendingPathComponent("php-app")
        try phpAppSnippet.write(toFile: snippetPath, atomically: true, encoding: .utf8)

    }
}
