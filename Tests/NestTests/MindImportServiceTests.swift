import Foundation
import NestLib

enum MindImportServiceTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func assert(_ condition: Bool, _ msg: String, file: String = #file, line: Int = #line) {
            if condition {
                passed += 1
            } else {
                failed += 1
                print("  FAIL: \(msg) (\(file):\(line))")
            }
        }

        // Test: parses supported live cloudflared config entries.
        do {
            let config = """
            tunnel: local-testing
            credentials-file: /Users/test/.cloudflared/abc.json

            ingress:
              - hostname: alza.waka.pt
                service: https://localhost:443
                originRequest:
                  noTLSVerify: true
                  httpHostHeader: alza.test

              - hostname: azo.waka.pt
                service: http://localhost:3999
                originRequest:
                  httpHostHeader: azo.waka.pt

              - hostname: ssh.waka.pt
                service: ssh://localhost:22

              - service: http_status:404
            """

            let snapshot = MindImportService.parseConfigString(config, configPath: "/tmp/config.yaml")
            assert(snapshot.tunnelName == "local-testing", "should parse tunnel name")
            assert(snapshot.credentialsFilePath == "/Users/test/.cloudflared/abc.json", "should parse credentials path")
            assert(snapshot.routes.count == 2, "should parse supported routes only")
            assert(snapshot.routes.contains { $0.publicHostname == "alza.waka.pt" && $0.kind == .php && $0.localDomain == "alza.test" }, "should parse php route")
            assert(snapshot.routes.contains { $0.publicHostname == "azo.waka.pt" && $0.kind == .app && $0.originPort == 3999 }, "should parse app route")
            assert(snapshot.warnings.count == 1, "should warn about unsupported custom routes")
        }

        return (passed, failed)
    }
}
