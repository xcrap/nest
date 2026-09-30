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

        // Test: the same hostname in several ingress rules (cloudflared allows it) must not crash.
        do {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nest-mind-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configPath = directory.appendingPathComponent("config.yml").path
            try """
            tunnel: t
            credentials-file: /tmp/t.json
            ingress:
              - hostname: app.example.com
                path: /api
                service: http://localhost:3000
                originRequest:
                  httpHostHeader: app.example.com
              - hostname: app.example.com
                service: http://localhost:3001
                originRequest:
                  httpHostHeader: app.example.com
              - service: http_status:404
            """.write(toFile: configPath, atomically: true, encoding: .utf8)
            var settings = AppSettings()
            settings.cloudflareSettings.configPath = configPath
            let payload = try MindImportService.buildPayload(from: directory, existingSites: [], currentSettings: settings)
            assert(payload.tunnelRoutes.filter { $0.publicHostname == "app.example.com" }.count == 1, "should import a repeated hostname once")
            assert(payload.warnings.contains { $0.contains("several cloudflared ingress rules") }, "should warn about repeated hostnames")
        } catch {
            failed += 1
            print("  FAIL: duplicate hostname import threw: \(error)")
        }

        return (passed, failed)
    }
}
