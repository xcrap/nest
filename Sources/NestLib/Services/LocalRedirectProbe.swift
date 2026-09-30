import Foundation

/// Verifies that ports 80/443 reach Nest's own Caddy, not merely any local web server
/// (Valet's nginx, macOS Apache or a container can also answer on those ports).
public enum LocalRedirectProbe {
    /// Nest renders `localhost { tls internal; respond 204 }`, so HTTPS answers exactly 204.
    /// Plain HTTP is redirected to HTTPS by Caddy, which identifies itself in `Server`.
    public static func isRedirectReachingCaddy() -> Bool {
        let https = SystemProcess.capture("/usr/bin/curl", arguments: [
            "--silent", "--insecure", "--output", "/dev/null",
            "--write-out", "%{http_code}", "--max-time", "2", "https://localhost:443/"
        ], timeout: 4)
        guard https.status == 0, https.output.trimmingCharacters(in: .whitespacesAndNewlines) == "204" else { return false }

        let http = SystemProcess.capture("/usr/bin/curl", arguments: [
            "--silent", "--output", "/dev/null", "--dump-header", "-", "--max-time", "2", "http://localhost:80/"
        ], timeout: 4)
        guard http.status == 0 else { return false }
        return isCaddyResponse(headers: http.output)
    }

    public static func isCaddyAdminReachable() -> Bool {
        SystemProcess.capture("/usr/bin/curl", arguments: [
            "--silent", "--fail", "--max-time", "2", "--output", "/dev/null", "http://localhost:2019/config/"
        ], timeout: 3).status == 0
    }

    public static func isCaddyResponse(headers: String) -> Bool {
        let lines = headers.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/") else { return false }
        let fields = Dictionary(
            lines.dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            },
            uniquingKeysWith: { first, _ in first }
        )
        if fields["server"]?.localizedCaseInsensitiveContains("caddy") == true { return true }
        let status = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        return (300..<400).contains(status) && fields["location"]?.hasPrefix("https://localhost") == true
    }
}
