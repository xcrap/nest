import Foundation
import NestLib

enum ConfigRendererTests {
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

        let renderer = ConfigRenderer(configDirectory: "/tmp/nest-test-config", frankenphpLogPath: "/tmp/nest-test-logs/frankenphp.log")

        // Test: renders running sites only
        do {
            let sites = [
                Site(name: "Running", domain: "running.test", rootPath: "/var/www/running", documentRoot: "public", status: .running),
                Site(name: "Stopped", domain: "stopped.test", rootPath: "/var/www/stopped", documentRoot: "public", status: .stopped),
            ]
            let caddyfile = renderer.render(sites: sites)
            assert(caddyfile.contains("running.test"), "should contain running site")
            assert(!caddyfile.contains("stopped.test"), "should not contain stopped site")
        }

        // Test: renders public document root
        do {
            let sites = [
                Site(name: "App", domain: "app.test", rootPath: "/var/www/app", documentRoot: "public", status: .running),
            ]
            let caddyfile = renderer.render(sites: sites)
            assert(caddyfile.contains("import php-app \"app.test\" \"/var/www/app\" \"/var/www/app/public\""), "should render public doc root")
        }

        // Test: renders dot document root
        do {
            let sites = [
                Site(name: "App", domain: "app.test", rootPath: "/var/www/app", documentRoot: ".", status: .running),
            ]
            let caddyfile = renderer.render(sites: sites)
            assert(caddyfile.contains("import php-app \"app.test\" \"/var/www/app\" \"/var/www/app\""), "should render dot doc root")
        }

        // Test: includes global options
        do {
            let caddyfile = renderer.render(sites: [])
            assert(caddyfile.contains("http_port 8080"), "should contain http_port")
            assert(caddyfile.contains("https_port 8443"), "should contain https_port")
            assert(caddyfile.contains("admin localhost:2019"), "should contain admin")
            assert(caddyfile.contains("local_certs"), "should contain local_certs")
        }

        // Test: includes localhost block
        do {
            let caddyfile = renderer.render(sites: [])
            assert(caddyfile.contains("localhost {"), "should contain localhost block")
            assert(caddyfile.contains("tls internal"), "should contain tls internal")
            assert(caddyfile.contains("respond 204"), "should contain respond 204")
        }

        // Test: writes all config files to disk
        do {
            let tmpDir = NSTemporaryDirectory() + "nest-test-\(UUID().uuidString)"
            let r = ConfigRenderer(configDirectory: tmpDir, frankenphpLogPath: tmpDir + "/logs/frankenphp.log")
            let sites = [
                Site(name: "App", domain: "app.test", rootPath: "/var/www/app", status: .running),
            ]

            try r.writeAll(sites: sites)

            let fm = FileManager.default
            assert(fm.fileExists(atPath: r.caddyfilePath), "Caddyfile should exist")
            assert(fm.fileExists(atPath: r.securityConfPath), "security.conf should exist")
            assert(fm.fileExists(atPath: (r.snippetsDirectory as NSString).appendingPathComponent("php-app")), "php-app snippet should exist")

            try? fm.removeItem(atPath: tmpDir)
        } catch {
            failed += 1
            print("  FAIL: writeAll threw: \(error)")
        }

        // Test: rejects invalid running sites before writing config.
        do {
            let tmpDir = NSTemporaryDirectory() + "nest-test-\(UUID().uuidString)"
            let r = ConfigRenderer(configDirectory: tmpDir, frankenphpLogPath: tmpDir + "/logs/frankenphp.log")
            let sites = [
                Site(name: "Bad", domain: "bad domain.test", rootPath: "/var/www/app", documentRoot: "../public", status: .running),
            ]

            do {
                try r.writeAll(sites: sites)
                failed += 1
                print("  FAIL: writeAll should reject invalid site")
            } catch ConfigRendererError.invalidConfiguration(let issues) {
                assert(issues.contains { $0.contains("invalid DNS label") }, "should report invalid domain")
                assert(issues.contains { $0.contains("site root") }, "should report unsafe document root")
            } catch {
                failed += 1
                print("  FAIL: writeAll threw unexpected error: \(error)")
            }

            try? FileManager.default.removeItem(atPath: tmpDir)
        }

        // Test: two running sites on one domain are reported before Caddy rejects the config.
        do {
            let running = [
                Site(name: "One", domain: "app.test", rootPath: "/var/www/one", documentRoot: ".", status: .running),
                Site(name: "Two", domain: "app.test", rootPath: "/var/www/two", documentRoot: ".", status: .running),
            ]
            let issues = renderer.validationIssues(sites: running)
            assert(issues.count == 1 && issues.first?.contains("2 running sites use this domain") == true, "should report a duplicate running domain once")
            var stopped = running
            stopped[1].status = .stopped
            assert(renderer.validationIssues(sites: stopped).isEmpty, "a stopped site may share a running site's domain")
        }

        return (passed, failed)
    }
}
