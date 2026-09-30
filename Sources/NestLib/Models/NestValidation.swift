import Foundation

public enum NestValidation {
    public static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizedDomain(_ value: String, defaultTLD: String? = nil) -> String {
        var domain = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if domain.hasSuffix(".") {
            domain.removeLast()
        }

        if let defaultTLD, !defaultTLD.isEmpty, !domain.isEmpty, !domain.hasSuffix(".\(defaultTLD)") {
            domain += ".\(defaultTLD)"
        }

        return domain
    }

    /// The editable label for a `.test` site domain: only the trailing TLD is removed.
    public static func siteDomainLabel(_ domain: String) -> String {
        domain.hasSuffix(".test") ? String(domain.dropLast(".test".count)) : domain
    }

    public static func normalizedRelativePath(_ value: String, fallback: String = ".") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    public static func siteIssues(_ site: Site) -> [String] {
        var issues: [String] = []

        if normalizedName(site.name).isEmpty {
            issues.append("Site name is required.")
        }

        issues.append(contentsOf: domainIssues(site.domain, field: "Site domain", requiredTLD: "test"))
        issues.append(contentsOf: absolutePathIssues(site.rootPath, field: "Site root path"))
        issues.append(contentsOf: relativePathIssues(site.documentRoot, field: "Document root"))
        issues.append(contentsOf: pathIssues(site.resolvedDocumentRoot, field: "Resolved document root"))
        issues.append(contentsOf: caddyPathIssues(site.resolvedDocumentRoot, field: "Site path"))

        return issues
    }

    /// Caddy expands `{…}` placeholders and has no backslash escape inside quoted tokens,
    /// so paths containing these characters would silently point somewhere else.
    public static func caddyPathIssues(_ value: String, field: String) -> [String] {
        value.contains(where: { "{}\\".contains($0) })
            ? ["\(field) cannot contain {, } or \\ characters."]
            : []
    }

    public static func projectIssues(_ project: AppProject) -> [String] {
        var issues: [String] = []

        if normalizedName(project.name).isEmpty {
            issues.append("Project name is required.")
        }

        issues.append(contentsOf: domainIssues(project.hostname, field: "Project hostname"))
        issues.append(contentsOf: absolutePathIssues(project.directory, field: "Project directory"))
        issues.append(contentsOf: portIssues(project.port, field: "Project port"))

        if containsControlCharacters(project.command) {
            issues.append("Project command cannot contain control characters.")
        }

        return issues
    }

    public static func tunnelRouteIssues(_ route: TunnelRoute) -> [String] {
        var issues: [String] = []

        if !isValidDNSLabel(route.subdomain) {
            issues.append("Tunnel subdomain must be a valid DNS label.")
        }

        issues.append(contentsOf: domainIssues(route.publicDomain, field: "Public domain"))
        issues.append(contentsOf: domainIssues(route.publicHostname, field: "Public hostname"))

        if !route.localDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(contentsOf: domainIssues(route.localDomain, field: "Local hostname"))
        }

        issues.append(contentsOf: portIssues(route.originPort, field: route.kind == .php ? "HTTPS port" : "Port"))

        return issues
    }

    public static func cloudflareSettingsIssues(_ settings: CloudflareSettings) -> [String] {
        var issues: [String] = []

        if settings.tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Cloudflare tunnel name is required.")
        }

        if !settings.tunnelDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(contentsOf: domainIssues(settings.tunnelDomain, field: "Cloudflare tunnel domain"))
        }

        issues.append(contentsOf: pathIssues(settings.configPath, field: "cloudflared config path"))
        issues.append(contentsOf: pathIssues(settings.credentialsFilePath, field: "cloudflared credentials path"))

        return issues
    }

    public static func normalizedCloudflareSettings(_ settings: CloudflareSettings) -> CloudflareSettings {
        var updated = settings
        updated.apiToken = settings.apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.zoneId = settings.zoneId.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.accountId = settings.accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.tunnelId = settings.tunnelId.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.tunnelName = settings.tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.tunnelDomain = normalizedDomain(settings.tunnelDomain)
        updated.configPath = settings.configPath.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.credentialsFilePath = settings.credentialsFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return updated
    }

    public static func domainIssues(_ value: String, field: String, requiredTLD: String? = nil) -> [String] {
        let domain = normalizedDomain(value)
        if domain.isEmpty {
            return ["\(field) is required."]
        }

        if containsControlCharacters(domain) {
            return ["\(field) cannot contain control characters."]
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count < 2 || labels.contains(where: { $0.isEmpty }) {
            return ["\(field) must be a fully-qualified domain name."]
        }

        if let requiredTLD, labels.last.map(String.init) != requiredTLD {
            return ["\(field) must end in .\(requiredTLD)."]
        }

        for label in labels where !isValidDNSLabel(String(label)) {
            return ["\(field) contains an invalid DNS label."]
        }

        return []
    }

    public static func absolutePathIssues(_ value: String, field: String) -> [String] {
        var issues = pathIssues(value, field: field)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !(trimmed as NSString).isAbsolutePath {
            issues.append("\(field) must be an absolute path.")
        }
        return issues
    }

    public static func pathIssues(_ value: String, field: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ["\(field) is required."]
        }

        if value.contains("\0") || containsControlCharacters(value) {
            return ["\(field) cannot contain control characters."]
        }

        return []
    }

    public static func relativePathIssues(_ value: String, field: String) -> [String] {
        let trimmed = normalizedRelativePath(value)
        if trimmed.isEmpty {
            return ["\(field) is required."]
        }

        if trimmed == "." {
            return []
        }

        if trimmed.hasPrefix("/") {
            return ["\(field) must be relative to the site root."]
        }

        if trimmed.contains("\\") || containsControlCharacters(trimmed) {
            return ["\(field) contains invalid characters."]
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return ["\(field) must stay inside the site root."]
        }

        return []
    }

    public static func portIssues(_ value: Int, field: String) -> [String] {
        (1...65_535).contains(value) ? [] : ["\(field) must be between 1 and 65535."]
    }

    public static func isValidDNSLabel(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 63 else { return false }
        guard value.first != "-", value.last != "-" else { return false }

        return value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || scalar == "-"
        }
    }

    /// Caddy only recognizes `\"` inside a quoted token; any other backslash is kept literally.
    /// Values reaching here are validated with `caddyPathIssues`, so only quotes need escaping.
    public static func caddyfileArgument(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    public static func yamlScalar(_ value: String) -> String {
        if isPlainYAMLScalar(value) {
            return value
        }
        return "\"\(escapedString(value))\""
    }

    public static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 32 || scalar.value == 127
        }
    }

    private static let yamlReservedWords: Set<String> = [
        "y", "n", "yes", "no", "true", "false", "on", "off", "null", "~"
    ]

    /// Plain scalars must stay strings: no leading indicator, trailing colon, keyword or number.
    private static func isPlainYAMLScalar(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, let last = value.unicodeScalars.last else { return false }
        let safeCharacters = value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || "-._~:/@".unicodeScalars.contains(scalar)
        }
        guard safeCharacters else { return false }
        guard !"-:~@.".unicodeScalars.contains(first), last != ":" else { return false }
        guard !yamlReservedWords.contains(value.lowercased()) else { return false }
        return Double(value) == nil && Int(value) == nil
    }

    private static func escapedString(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }

        return escaped
    }
}
