import Foundation
import NestLib

enum TunnelConfigRendererTests {
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

        let settings = CloudflareSettings(
            tunnelName: "local-testing",
            tunnelDomain: "abc.cfargotunnel.com",
            configPath: "/tmp/cloudflared/config.yaml",
            credentialsFilePath: "/Users/test/.cloudflared/abc.json"
        )
        let renderer = TunnelConfigRenderer(settings: settings)

        // Test: resolves linked PHP and app routes using current Nest state.
        do {
            let sites = [
                Site(name: "Alza", domain: "alza.test", rootPath: "/Users/test/alza", status: .running)
            ]
            let projects = [
                AppProject(name: "Azo", hostname: "azo.waka.pt", directory: "/Users/test/azo", port: 3999)
            ]
            let routes = [
                TunnelRoute(kind: .php, subdomain: "alza", publicDomain: "waka.pt", localDomain: "legacy.test", originPort: 443, linkedSiteDomain: "alza.test"),
                TunnelRoute(kind: .app, subdomain: "azo", publicDomain: "waka.pt", localDomain: "old.waka.pt", originPort: 3000, linkedProjectID: projects[0].id)
            ]

            let resolved = renderer.resolvedRoutes(routes: routes, sites: sites, projects: projects)
            assert(resolved.count == 2, "should resolve both supported routes")
            assert(resolved.contains { $0.hostname == "alza.waka.pt" && $0.httpHostHeader == "alza.test" && $0.service == "https://localhost:443" }, "should resolve linked php site")
            assert(resolved.contains { $0.hostname == "azo.waka.pt" && $0.httpHostHeader == "azo.waka.pt" && $0.service == "http://localhost:3999" }, "should resolve linked app project")
        }

        // Test: render includes fallback and credentials metadata.
        do {
            let content = renderer.render(routes: [], sites: [], projects: [])
            assert(content.contains("tunnel: local-testing"), "should include tunnel name")
            assert(content.contains("credentials-file: /Users/test/.cloudflared/abc.json"), "should include credentials file")
            assert(content.contains("http_status:404"), "should include fallback service")
        }

        return (passed, failed)
    }
}
