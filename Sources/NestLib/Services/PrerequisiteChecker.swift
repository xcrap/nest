import Foundation

/// Checks manual system prerequisites for .test domain and HTTPS support.
public struct PrerequisiteChecker {
    public struct CheckResult: Identifiable {
        public let id = UUID()
        public let name: String
        public let passed: Bool
        public let detail: String
        public let fixHint: String

        public init(name: String, passed: Bool, detail: String, fixHint: String) {
            self.name = name
            self.passed = passed
            self.detail = detail
            self.fixHint = fixHint
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

    /// Check if dnsmasq is installed and running.
    public static func checkDnsmasq() -> CheckResult {
        let fm = FileManager.default
        let binary = "/opt/homebrew/opt/dnsmasq/sbin/dnsmasq"
        let config = "/opt/homebrew/etc/dnsmasq.conf"

        guard fm.fileExists(atPath: binary) else {
            return CheckResult(
                name: "dnsmasq",
                passed: false,
                detail: "dnsmasq is not installed. It resolves *.test domains to 127.0.0.1.",
                fixHint: """
                brew install dnsmasq
                printf 'port=5354\\naddress=/.test/127.0.0.1\\nlisten-address=127.0.0.1\\n' > /opt/homebrew/etc/dnsmasq.conf
                brew services start dnsmasq
                """
            )
        }

        // Check config has .test entry
        let configOK: Bool
        if let content = try? String(contentsOfFile: config, encoding: .utf8) {
            configOK = content.contains("address=/.test/127.0.0.1")
        } else {
            configOK = false
        }

        if !configOK {
            return CheckResult(
                name: "dnsmasq",
                passed: false,
                detail: "dnsmasq is installed but not configured for .test domains.",
                fixHint: """
                printf 'port=5354\\naddress=/.test/127.0.0.1\\nlisten-address=127.0.0.1\\n' > /opt/homebrew/etc/dnsmasq.conf
                brew services restart dnsmasq
                """
            )
        }

        // Check if running
        let running = isProcessRunning("dnsmasq")
        if !running {
            return CheckResult(
                name: "dnsmasq",
                passed: false,
                detail: "dnsmasq is configured but not running.",
                fixHint: "brew services start dnsmasq"
            )
        }

        return CheckResult(
            name: "dnsmasq",
            passed: true,
            detail: "dnsmasq is running and configured for *.test domains.",
            fixHint: ""
        )
    }

    /// Check if /etc/resolver/test exists with the correct content.
    public static func checkResolver() -> CheckResult {
        let path = "/etc/resolver/test"
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else {
            return CheckResult(
                name: "DNS Resolver",
                passed: false,
                detail: "/etc/resolver/test does not exist.",
                fixHint: "sudo bash -c 'printf \"nameserver 127.0.0.1\\nport 5354\\n\" > /etc/resolver/test'"
            )
        }

        if let content = try? String(contentsOfFile: path, encoding: .utf8),
           content.contains("127.0.0.1"), content.contains("5354") {
            return CheckResult(
                name: "DNS Resolver",
                passed: true,
                detail: "/etc/resolver/test is configured (port 5354).",
                fixHint: ""
            )
        }

        return CheckResult(
            name: "DNS Resolver",
            passed: false,
            detail: "/etc/resolver/test exists but may be misconfigured.",
            fixHint: "sudo bash -c 'printf \"nameserver 127.0.0.1\\nport 5354\\n\" > /etc/resolver/test'"
        )
    }

    /// Check if the Caddy local CA certificate is trusted.
    public static func checkLocalCA() -> CheckResult {
        let home = NSHomeDirectory()
        let caCertPath = "\(home)/Library/Application Support/Caddy/pki/authorities/local/root.crt"

        guard FileManager.default.fileExists(atPath: caCertPath) else {
            return CheckResult(
                name: "Local CA Certificate",
                passed: false,
                detail: "Caddy local CA certificate not found. Start FrankenPHP once to generate it.",
                fixHint: "brew services start frankenphp\nThen trust the CA:\n  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \"\(caCertPath)\""
            )
        }

        return CheckResult(
            name: "Local CA Certificate",
            passed: true,
            detail: "Caddy local CA certificate exists.\nIf HTTPS doesn't work, ensure it's trusted in Keychain.",
            fixHint: "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \"\(caCertPath)\""
        )
    }

    /// Check if PF anchor for port redirect exists.
    public static func checkPFAnchor() -> CheckResult {
        let anchorName = "dev.nest.app"
        let anchorPath = "/etc/pf.anchors/dev.nest.app"
        let pfConfPath = "/etc/pf.conf"

        guard FileManager.default.fileExists(atPath: anchorPath) else {
            return CheckResult(
                name: "Port Redirect (PF)",
                passed: false,
                detail: "PF anchor not found. Ports 80/443 won't redirect to 8080/8443.",
                fixHint: """
                sudo bash -c 'printf "rdr pass on lo0 inet proto tcp from any to any port 80 -> 127.0.0.1 port 8080\\nrdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port 8443\\n" > /etc/pf.anchors/dev.nest.app'

                Add to /etc/pf.conf (before any existing anchor lines):
                  rdr-anchor "dev.nest.app"
                  load anchor "dev.nest.app" from "/etc/pf.anchors/dev.nest.app"

                Then reload: sudo pfctl -ef /etc/pf.conf
                """
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
                name: "Port Redirect (PF)",
                passed: false,
                detail: "/etc/pf.conf does not currently load the Nest PF anchor.",
                fixHint: """
                Add to /etc/pf.conf (before any existing anchor lines):
                  rdr-anchor "\(anchorName)"
                  load anchor "\(anchorName)" from "\(anchorPath)"

                Then reload: sudo pfctl -ef /etc/pf.conf
                """
            )
        }

        if isPortRedirectWorking() {
            return CheckResult(
                name: "Port Redirect (PF)",
                passed: true,
                detail: "PF redirect is active. Local requests on ports 80/443 reach FrankenPHP.",
                fixHint: ""
            )
        }

        if isCaddyAdminReachable() {
            return CheckResult(
                name: "Port Redirect (PF)",
                passed: false,
                detail: "FrankenPHP is running, but ports 80/443 are not redirecting to 8080/8443 right now.",
                fixHint: "Reload with: sudo pfctl -ef /etc/pf.conf"
            )
        }

        return CheckResult(
            name: "Port Redirect (PF)",
            passed: true,
            detail: "PF rules are configured on disk. Start FrankenPHP to verify live 80/443 redirects.",
            fixHint: "If redirects aren't working, reload with: sudo pfctl -ef /etc/pf.conf"
        )
    }

    private static func isProcessRunning(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func isPortRedirectWorking() -> Bool {
        isHTTPEndpointReachable("http://localhost:80") &&
            isHTTPEndpointReachable("https://localhost:443", insecureTLS: true)
    }

    private static func isCaddyAdminReachable() -> Bool {
        isHTTPEndpointReachable("http://localhost:2019/config/")
    }

    private static func isHTTPEndpointReachable(_ url: String, insecureTLS: Bool = false) -> Bool {
        var arguments = [
            "-I",
            "--silent",
            "--output", "/dev/null",
            "--write-out", "%{http_code}",
            "--max-time", "2"
        ]

        if insecureTLS {
            arguments.append("-k")
        }

        arguments.append(url)

        let result = SystemProcess.capture("/usr/bin/curl", arguments: arguments)
        guard result.status == 0 else { return false }

        let statusCode = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !statusCode.isEmpty && statusCode != "000"
    }
}
