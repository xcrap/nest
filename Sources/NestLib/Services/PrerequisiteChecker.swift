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
        results.append(checkResolver())
        results.append(checkLocalCA())
        results.append(checkPFAnchor())
        return results
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
                fixHint: "Create it with:\n  sudo mkdir -p /etc/resolver\n  echo 'nameserver 127.0.0.1\\nport 5353' | sudo tee /etc/resolver/test"
            )
        }

        if let content = try? String(contentsOfFile: path, encoding: .utf8),
           content.contains("127.0.0.1") {
            return CheckResult(
                name: "DNS Resolver",
                passed: true,
                detail: "/etc/resolver/test is configured.",
                fixHint: ""
            )
        }

        return CheckResult(
            name: "DNS Resolver",
            passed: false,
            detail: "/etc/resolver/test exists but may be misconfigured.",
            fixHint: "Verify it contains:\n  nameserver 127.0.0.1\n  port 5353"
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
                fixHint: "Start FrankenPHP, then trust the CA:\n  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \"\(caCertPath)\""
            )
        }

        return CheckResult(
            name: "Local CA Certificate",
            passed: true,
            detail: "Caddy local CA certificate exists at \(caCertPath).\nIf HTTPS doesn't work, ensure it's trusted in Keychain.",
            fixHint: "Trust it with:\n  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \"\(caCertPath)\""
        )
    }

    /// Check if PF anchor for port redirect exists.
    public static func checkPFAnchor() -> CheckResult {
        let anchorPath = "/etc/pf.anchors/dev.nest.app"

        guard FileManager.default.fileExists(atPath: anchorPath) else {
            return CheckResult(
                name: "Port Redirect (PF)",
                passed: false,
                detail: "PF anchor not found. Ports 80/443 won't redirect to 8080/8443.",
                fixHint: """
                Create the anchor file:
                  echo 'rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port 8080
                rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port 8443' | sudo tee /etc/pf.anchors/dev.nest.app

                Then add to /etc/pf.conf:
                  rdr-anchor "dev.nest.app"
                  load anchor "dev.nest.app" from "/etc/pf.anchors/dev.nest.app"

                And reload: sudo pfctl -f /etc/pf.conf
                """
            )
        }

        return CheckResult(
            name: "Port Redirect (PF)",
            passed: true,
            detail: "PF anchor exists at \(anchorPath).",
            fixHint: "If redirects aren't working, reload with: sudo pfctl -f /etc/pf.conf"
        )
    }
}
