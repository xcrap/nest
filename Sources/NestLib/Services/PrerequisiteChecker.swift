import Foundation

/// Checks manual system prerequisites for .test domain and HTTPS support.
public struct PrerequisiteChecker {
    public enum CheckID: String, CaseIterable {
        case dnsmasq
        case resolver
        case localCA
        case pfAnchor
    }

    public enum CheckCategory: String, Equatable {
        case dns
        case tls
        case networking
    }

    public enum CheckSeverity: String, Equatable {
        case info
        case warning
        case error
    }

    public enum CheckAction: Equatable {
        case none
        case installPFHelper
        case repairPFHelper
        case uninstallPFHelper
        case openPFHelperSettings
    }

    public struct CheckResult: Identifiable {
        public let id: CheckID
        public let category: CheckCategory
        public let name: String
        public let passed: Bool
        public let severity: CheckSeverity
        public let detail: String
        public let fixHint: String
        public let fixCommands: [String]
        public let action: CheckAction

        public init(
            id: CheckID,
            category: CheckCategory,
            name: String,
            passed: Bool,
            severity: CheckSeverity? = nil,
            detail: String,
            fixHint: String,
            fixCommands: [String] = [],
            action: CheckAction = .none
        ) {
            self.id = id
            self.category = category
            self.name = name
            self.passed = passed
            self.severity = severity ?? (passed ? .info : .error)
            self.detail = detail
            self.fixHint = fixHint
            self.fixCommands = fixCommands
            self.action = action
        }
    }

    /// Run all prerequisite checks and return results.
    public static func checkAll() -> [CheckResult] {
        var results: [CheckResult] = []
        results.append(checkDnsmasq())
        results.append(checkResolver())
        results.append(checkLocalCA())
        results.append(checkPFAnchor())
        return results
    }

    public static let dnsmasqConfigPath = "/opt/homebrew/etc/dnsmasq.conf"
    public static let nestDNSPort = 5354

    /// What dnsmasq's active (uncommented) configuration does for `.test`, including included files.
    public struct DnsmasqConfiguration: Equatable {
        public var port: Int
        public var resolvesTestDomains: Bool

        public init(port: Int, resolvesTestDomains: Bool) {
            self.port = port
            self.resolvesTestDomains = resolvesTestDomains
        }
    }

    public static func parseDnsmasqConfiguration(_ content: String, includedFiles: (String) -> [String] = defaultIncludedFiles) -> DnsmasqConfiguration {
        var port = 53
        var resolvesTest = false

        func apply(_ text: String, allowIncludes: Bool) {
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "port":
                    port = Int(parts[1]) ?? port
                case "address":
                    if ["/.test/127.0.0.1", "/test/127.0.0.1"].contains(parts[1]) { resolvesTest = true }
                case "conf-file", "conf-dir":
                    guard allowIncludes else { continue }
                    for file in includedFiles(line) {
                        if let included = try? String(contentsOfFile: file, encoding: .utf8) { apply(included, allowIncludes: false) }
                    }
                default:
                    continue
                }
            }
        }

        apply(content, allowIncludes: true)
        return DnsmasqConfiguration(port: port, resolvesTestDomains: resolvesTest)
    }

    /// Resolves `conf-file=<path>` and `conf-dir=<dir>[,*.ext]` lines to file paths.
    public static func defaultIncludedFiles(_ line: String) -> [String] {
        let value = line.split(separator: "=", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if line.hasPrefix("conf-file") { return [value] }
        let parts = value.split(separator: ",").map(String.init)
        guard let directory = parts.first else { return [] }
        let suffix = parts.dropFirst().first.map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && !$0.hasSuffix("~") && (suffix == nil || $0.hasSuffix(suffix!)) }
            .sorted()
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    public static func readDnsmasqConfiguration() -> DnsmasqConfiguration? {
        guard let content = try? String(contentsOfFile: dnsmasqConfigPath, encoding: .utf8) else { return nil }
        return parseDnsmasqConfiguration(content)
    }

    /// The port macOS should ask for `.test`: dnsmasq's own port once it serves `.test`, else Nest's default.
    public static func expectedResolverPort(dnsmasq: DnsmasqConfiguration?) -> Int {
        guard let dnsmasq, dnsmasq.resolvesTestDomains else { return nestDNSPort }
        return dnsmasq.port
    }

    /// Returns the port a resolver file points at, or nil when it does not target 127.0.0.1.
    public static func resolverPort(_ content: String) -> Int? {
        var nameserver = false
        var port = 53
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            if fields[0] == "nameserver", fields[1] == "127.0.0.1" { nameserver = true }
            if fields[0] == "port", let value = Int(fields[1]) { port = value }
        }
        return nameserver ? port : nil
    }

    private static let dnsmasqNestConfig = "port=5354\\naddress=/.test/127.0.0.1\\nlisten-address=127.0.0.1\\n"
    /// Keeps the first copy of the user's own config before Nest writes a minimal one.
    private static let writeDnsmasqConfigCommand =
        "cp -n \(dnsmasqConfigPath) \(dnsmasqConfigPath).nest-backup 2>/dev/null; printf '\(dnsmasqNestConfig)' > \(dnsmasqConfigPath)"

    private static func resolverFixCommand(port: Int) -> String {
        "sudo mkdir -p /etc/resolver && sudo bash -c 'printf \"nameserver 127.0.0.1\\nport \(port)\\n\" > /etc/resolver/test'"
    }

    /// Check if dnsmasq is installed and running.
    public static func checkDnsmasq() -> CheckResult {
        let fm = FileManager.default
        let binary = "/opt/homebrew/opt/dnsmasq/sbin/dnsmasq"

        guard fm.fileExists(atPath: binary) else {
            return CheckResult(
                id: .dnsmasq,
                category: .dns,
                name: "dnsmasq",
                passed: false,
                detail: "dnsmasq is not installed. It resolves *.test domains to 127.0.0.1.",
                fixHint: """
                brew install dnsmasq
                \(writeDnsmasqConfigCommand)
                brew services start dnsmasq
                """,
                fixCommands: [
                    "brew install dnsmasq",
                    writeDnsmasqConfigCommand,
                    "brew services start dnsmasq"
                ]
            )
        }

        guard let configuration = readDnsmasqConfiguration(), configuration.resolvesTestDomains else {
            return CheckResult(
                id: .dnsmasq,
                category: .dns,
                name: "dnsmasq",
                passed: false,
                detail: "dnsmasq is installed but not configured for .test domains. The fix keeps a copy of your current config at \(dnsmasqConfigPath).nest-backup.",
                fixHint: """
                \(writeDnsmasqConfigCommand)
                brew services restart dnsmasq
                """,
                fixCommands: [
                    writeDnsmasqConfigCommand,
                    "brew services restart dnsmasq"
                ]
            )
        }

        // Check if running
        let running = isProcessRunning("dnsmasq")
        if !running {
            return CheckResult(
                id: .dnsmasq,
                category: .dns,
                name: "dnsmasq",
                passed: false,
                detail: "dnsmasq is configured but not running.",
                fixHint: "brew services start dnsmasq",
                fixCommands: ["brew services start dnsmasq"]
            )
        }

        return CheckResult(
            id: .dnsmasq,
            category: .dns,
            name: "dnsmasq",
            passed: true,
            detail: "dnsmasq is running and resolves *.test domains on port \(configuration.port).",
            fixHint: ""
        )
    }

    /// Check if /etc/resolver/test points at the port dnsmasq actually serves.
    public static func checkResolver() -> CheckResult {
        let path = "/etc/resolver/test"
        let expectedPort = expectedResolverPort(dnsmasq: readDnsmasqConfiguration())
        let fix = resolverFixCommand(port: expectedPort)

        guard FileManager.default.fileExists(atPath: path) else {
            return CheckResult(
                id: .resolver,
                category: .dns,
                name: "DNS Resolver",
                passed: false,
                detail: "/etc/resolver/test does not exist.",
                fixHint: fix,
                fixCommands: [fix]
            )
        }

        let configuredPort = (try? String(contentsOfFile: path, encoding: .utf8)).flatMap(resolverPort)
        if configuredPort == expectedPort {
            return CheckResult(
                id: .resolver,
                category: .dns,
                name: "DNS Resolver",
                passed: true,
                detail: "/etc/resolver/test is configured (port \(expectedPort)).",
                fixHint: ""
            )
        }

        let detail = configuredPort.map { "/etc/resolver/test uses port \($0), but dnsmasq answers on port \(expectedPort)." }
            ?? "/etc/resolver/test does not point at 127.0.0.1."
        return CheckResult(
            id: .resolver,
            category: .dns,
            name: "DNS Resolver",
            passed: false,
            detail: detail,
            fixHint: fix,
            fixCommands: [fix]
        )
    }

    /// Check that the Caddy local CA certificate exists and is trusted by macOS.
    public static func checkLocalCA() -> CheckResult {
        let home = NSHomeDirectory()
        let caCertPath = "\(home)/Library/Application Support/Caddy/pki/authorities/local/root.crt"
        let trustCommand = "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \"\(caCertPath)\""

        guard FileManager.default.fileExists(atPath: caCertPath) else {
            return CheckResult(
                id: .localCA,
                category: .tls,
                name: "Local CA Certificate",
                passed: false,
                detail: "Caddy local CA certificate not found. Start FrankenPHP once to generate it.",
                fixHint: "brew services start frankenphp\nThen trust the CA:\n  \(trustCommand)",
                fixCommands: [
                    "brew services start frankenphp",
                    trustCommand
                ]
            )
        }

        let verification = SystemProcess.capture("/usr/bin/security", arguments: ["verify-cert", "-c", caCertPath], timeout: 10)
        guard verification.status == 0 else {
            return CheckResult(
                id: .localCA,
                category: .tls,
                name: "Local CA Certificate",
                passed: false,
                detail: "Caddy local CA certificate exists but macOS does not trust it, so browsers will reject HTTPS for .test sites.",
                fixHint: trustCommand,
                fixCommands: [trustCommand]
            )
        }

        return CheckResult(
            id: .localCA,
            category: .tls,
            name: "Local CA Certificate",
            passed: true,
            detail: "Caddy local CA certificate is trusted by macOS.",
            fixHint: ""
        )
    }

    /// Check if PF anchor for port redirect exists.
    public static func checkPFAnchor() -> CheckResult {
        if PFHelperManager.isSupported {
            return checkPFAnchorViaHelper()
        }
        return checkPFAnchorLegacy()
    }

    private static func checkPFAnchorViaHelper() -> CheckResult {
        switch PFHelperManager.status {
        case .enabled:
            if isPortRedirectWorking() {
                return CheckResult(
                    id: .pfAnchor,
                    category: .networking,
                    name: "Port Redirect (PF)",
                    passed: true,
                    detail: "Managed by Nest helper. Ports 80/443 redirect to 8080/8443 automatically on every boot.",
                    fixHint: ""
                )
            }
            if isCaddyAdminReachable() {
                return CheckResult(
                    id: .pfAnchor,
                    category: .networking,
                    name: "Port Redirect (PF)",
                    passed: false,
                    severity: .warning,
                    detail: "Nest helper is enabled but redirect isn't live. It will retry automatically; you can also re-run it now.",
                    fixHint: "",
                    action: .repairPFHelper
                )
            }
            return CheckResult(
                id: .pfAnchor,
                category: .networking,
                name: "Port Redirect (PF)",
                passed: true,
                detail: "Nest helper is enabled. Start FrankenPHP to verify live 80/443 redirects.",
                fixHint: ""
            )
        case .requiresApproval:
            return CheckResult(
                id: .pfAnchor,
                category: .networking,
                name: "Port Redirect (PF)",
                passed: false,
                detail: "Nest helper needs one-time approval in System Settings → General → Login Items & Extensions.",
                fixHint: "",
                action: .openPFHelperSettings
            )
        case .notRegistered, .notFound, .unknown, .unsupported:
            return CheckResult(
                id: .pfAnchor,
                category: .networking,
                name: "Port Redirect (PF)",
                passed: false,
                detail: "Install the Nest privileged helper so ports 80/443 redirect to 8080/8443 automatically on every boot.",
                fixHint: "",
                action: .installPFHelper
            )
        }
    }

    private static func checkPFAnchorLegacy() -> CheckResult {
        let anchorName = "dev.nest.app"
        let anchorPath = "/etc/pf.anchors/dev.nest.app"
        let pfConfPath = "/etc/pf.conf"

        guard FileManager.default.fileExists(atPath: anchorPath) else {
            return CheckResult(
                id: .pfAnchor,
                category: .networking,
                name: "Port Redirect (PF)",
                passed: false,
                detail: "PF anchor not found. Ports 80/443 won't redirect to 8080/8443.",
                fixHint: """
                sudo bash -c 'printf "rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port 8080\\nrdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port 8443\\n" > /etc/pf.anchors/dev.nest.app'

                Add to /etc/pf.conf directly above the line rdr-anchor "com.apple/*"
                (pfctl rejects translation rules placed before scrub-anchor):
                  rdr-anchor "dev.nest.app"
                  load anchor "dev.nest.app" from "/etc/pf.anchors/dev.nest.app"

                Then reload: sudo pfctl -ef /etc/pf.conf
                """,
                fixCommands: [
                    "sudo bash -c 'printf \"rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port 8080\\nrdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port 8443\\n\" > /etc/pf.anchors/dev.nest.app'",
                    "sudo pfctl -ef /etc/pf.conf"
                ]
            )
        }

        let pfConfLoaded: Bool
        if let content = try? String(contentsOfFile: pfConfPath, encoding: .utf8) {
            pfConfLoaded =
                content.contains("rdr-anchor \"\(anchorName)\"") &&
                content.contains("load anchor \"\(anchorName)\" from \"\(anchorPath)\"")
        } else {
            pfConfLoaded = false
        }

        if !pfConfLoaded {
            return CheckResult(
                id: .pfAnchor,
                category: .networking,
                name: "Port Redirect (PF)",
                passed: false,
                detail: "/etc/pf.conf does not currently load the Nest PF anchor.",
                fixHint: """
                Add to /etc/pf.conf directly above the line rdr-anchor "com.apple/*"
                (pfctl rejects translation rules placed before scrub-anchor):
                  rdr-anchor "\(anchorName)"
                  load anchor "\(anchorName)" from "\(anchorPath)"

                Then reload: sudo pfctl -ef /etc/pf.conf
                """,
                fixCommands: ["sudo pfctl -ef /etc/pf.conf"]
            )
        }

        if isPortRedirectWorking() {
            return CheckResult(
                id: .pfAnchor,
                category: .networking,
                name: "Port Redirect (PF)",
                passed: true,
                detail: "PF redirect is active. Local requests on ports 80/443 reach FrankenPHP.",
                fixHint: ""
            )
        }

        if isCaddyAdminReachable() {
            return CheckResult(
                id: .pfAnchor,
                category: .networking,
                name: "Port Redirect (PF)",
                passed: false,
                detail: "FrankenPHP is running, but ports 80/443 do not reach it. PF may not be loaded, or another local server is answering on those ports.",
                fixHint: "Reload with: sudo pfctl -ef /etc/pf.conf",
                fixCommands: ["sudo pfctl -ef /etc/pf.conf"]
            )
        }

        return CheckResult(
            id: .pfAnchor,
            category: .networking,
            name: "Port Redirect (PF)",
            passed: true,
            detail: "PF rules are configured on disk. Start FrankenPHP to verify live 80/443 redirects.",
            fixHint: "If redirects aren't working, reload with: sudo pfctl -ef /etc/pf.conf",
            fixCommands: ["sudo pfctl -ef /etc/pf.conf"]
        )
    }

    private static func isProcessRunning(_ name: String) -> Bool {
        SystemProcess.capture("/usr/bin/pgrep", arguments: ["-x", name], timeout: 3).status == 0
    }

    private static func isPortRedirectWorking() -> Bool {
        LocalRedirectProbe.isRedirectReachingCaddy()
    }

    private static func isCaddyAdminReachable() -> Bool {
        LocalRedirectProbe.isCaddyAdminReachable()
    }
}
