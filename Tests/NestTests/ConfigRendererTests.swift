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
            let caddyfile = renderer.render(sites: sites, projects: [])
            assert(caddyfile.contains("running.test"), "should contain running site")
            assert(!caddyfile.contains("stopped.test"), "should not contain stopped site")
        }

        // Test: renders public document root
        do {
            let sites = [
                Site(name: "App", domain: "app.test", rootPath: "/var/www/app", documentRoot: "public", status: .running),
            ]
            let caddyfile = renderer.render(sites: sites, projects: [])
            assert(caddyfile.contains("import php-app \"app.test\" \"/var/www/app\" \"/var/www/app/public\""), "should render public doc root")
        }

        // Test: renders dot document root
        do {
            let sites = [
                Site(name: "App", domain: "app.test", rootPath: "/var/www/app", documentRoot: ".", status: .running),
            ]
            let caddyfile = renderer.render(sites: sites, projects: [])
            assert(caddyfile.contains("import php-app \"app.test\" \"/var/www/app\" \"/var/www/app\""), "should render dot doc root")
        }

        // Test: includes global options
        do {
            let caddyfile = renderer.render(sites: [], projects: [])
            assert(caddyfile.contains("http_port 8080"), "should contain http_port")
            assert(caddyfile.contains("https_port 8443"), "should contain https_port")
            assert(caddyfile.contains("admin localhost:2019"), "should contain admin")
            assert(caddyfile.contains("local_certs"), "should contain local_certs")
        }

        // Test: includes localhost block
        do {
            let caddyfile = renderer.render(sites: [], projects: [])
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

            try r.writeAll(sites: sites, projects: [])

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
                try r.writeAll(sites: sites, projects: [])
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
            let issues = renderer.validationIssues(sites: running, projects: [])
            assert(issues.count == 1 && issues.first?.contains("2 running sites use this domain") == true, "should report a duplicate running domain once")
            var stopped = running
            stopped[1].status = .stopped
            assert(renderer.validationIssues(sites: stopped, projects: []).isEmpty, "a stopped site may share a running site's domain")
        }

        // Test: a project with a local domain gets an HTTPS reverse proxy to its loopback port.
        do {
            let projects = [
                AppProject(name: "Vite", hostname: "vite.example.com", directory: "/tmp/vite", port: 5173, localDomain: "vite.test"),
                AppProject(name: "Plain", hostname: "plain.example.com", directory: "/tmp/plain", port: 3000),
            ]
            let caddyfile = renderer.render(sites: [], projects: projects)
            let block = """
            vite.test {
                tls internal
                reverse_proxy 127.0.0.1:5173 {
                    header_up Host {upstream_hostport}
                }
            }
            """
            assert(caddyfile.contains(block), "should render the project proxy block")
            assert(!caddyfile.contains("plain.example.com") && !caddyfile.contains("127.0.0.1:3000"), "should skip projects without a local domain")
            assert(renderer.validationIssues(sites: [], projects: projects).isEmpty, "a valid project local domain has no issues")
            let withSite = renderer.render(sites: [Site(name: "App", domain: "app.test", rootPath: "/var/www/app", status: .running)], projects: projects)
            assert(withSite.contains("import php-app \"app.test\"") && withSite.contains("vite.test {"), "sites and projects render together")
        }

        // Test: a local domain shared with a running site or another project is reported.
        do {
            let project = AppProject(name: "Vite", hostname: "vite.example.com", directory: "/tmp/vite", port: 5173, localDomain: "app.test")
            let site = Site(name: "App", domain: "app.test", rootPath: "/var/www/app", documentRoot: ".", status: .running)
            let siteClash = renderer.validationIssues(sites: [site], projects: [project])
            assert(siteClash == ["app.test: a running site and the project 'Vite' use this domain; give each its own."],
                   "should report a project sharing a running site's domain")
            var stopped = site
            stopped.status = .stopped
            assert(renderer.validationIssues(sites: [stopped], projects: [project]).isEmpty, "a stopped site does not reach Caddy")
            var second = project
            second.id = "second"
            second.name = "Next"
            let projectClash = renderer.validationIssues(sites: [], projects: [project, second])
            assert(projectClash == ["app.test: the project 'Vite' and the project 'Next' use this domain; give each its own."],
                   "should report two projects on one local domain")
            let threeWay = renderer.validationIssues(sites: [site], projects: [project, second])
            assert(threeWay == ["app.test: a running site, the project 'Vite', and the project 'Next' use this domain; give each its own."],
                   "should list every user of a shared domain")
        }

        // Test: a hand-edited, invalid local domain blocks the write instead of breaking the Caddyfile.
        do {
            let tmpDir = NSTemporaryDirectory() + "nest-test-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }
            let r = ConfigRenderer(configDirectory: tmpDir, frankenphpLogPath: "")
            let bad = AppProject(name: "Bad", hostname: "bad.example.com", directory: "/tmp/bad", port: 0, localDomain: "bad.example.com")
            do {
                try r.writeAll(sites: [], projects: [bad])
                assert(false, "writeAll should reject an invalid local domain")
            } catch ConfigRendererError.invalidConfiguration(let issues) {
                assert(issues.contains("bad.example.com: Local domain must end in .test."), "should report the non-.test local domain")
                assert(issues.contains { $0.contains("Project port") }, "should report the unusable port")
                assert(!FileManager.default.fileExists(atPath: r.caddyfilePath), "should not write a Caddyfile")
            } catch {
                assert(false, "writeAll threw unexpected error: \(error)")
            }
        }

        return (passed, failed)
    }
}
