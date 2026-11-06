import Foundation
import NestLib

@MainActor
enum StorageApplyTests {
    static func runAll() async -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 }
            else { failed += 1; print("  FAIL: \(message)") }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nest-storage-apply-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            for file in StoreFile.allCases {
                let directory = root.appendingPathComponent(file.rawValue)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let corrupt = Data("{broken".utf8)
                try corrupt.write(to: directory.appendingPathComponent(file.fileName))
                var settings = AppSettings(caddyConfigDirectory: directory.appendingPathComponent("caddy").path)
                settings.runtimePaths.frankenphpBinary = directory.appendingPathComponent("missing-frankenphp").path
                settings.cloudflareSettings = CloudflareSettings(zoneId: "zone", accountId: "account", tunnelId: "id",
                    tunnelName: "fixture", tunnelDomain: "id.cfargotunnel.com",
                    configPath: directory.appendingPathComponent("tunnel.yml").path,
                    credentialsFilePath: directory.appendingPathComponent("credentials.json").path)
                let store = SiteStore(dataDirectory: directory, defaults: settings, runOneTimeMigrations: false,
                                      credentialStore: MemoryCredentialStore(token: "fixture-token"))
                check(store.saveError(file) == nil, "unreadable \(file.fileName) reproduces a read failure without a save failure")
                var publications = 0
                let controller = ProcessController(applyTunnel: { _, _, _, _, _, _ in publications += 1; return "Applied" })
                controller.markTunnelsPending(store: store)
                store.settings.runtimePaths.cloudflaredLog = directory.appendingPathComponent("new.log").path
                controller.markTunnelsPending(store: store, automaticallyApply: true)
                controller.applyTunnels(store: store, push: true, start: true)
                await Task.yield()
                check(publications == 0 && !controller.isServiceBusy("Cloudflared"), "unreadable \(file.fileName) blocks automatic and manual publication/start")
                check(controller.cloudflaredError?.contains(file.fileName) == true, "blocked publication identifies \(file.fileName)")
                if file == .sites || file == .settings {
                    controller.markCaddyPending(store: store)
                    controller.applyCaddy(store: store)
                    controller.startFrankenPHP(store: store)
                    await Task.yield()
                    check(controller.frankenphpError?.contains(file.fileName) == true && !controller.caddyApplyState.isBusy,
                          "unreadable \(file.fileName) blocks Caddy Apply and Start")
                    check(!fm.fileExists(atPath: settings.caddyConfigDirectory), "blocked Caddy operation writes no config files")
                } else {
                    check(store.caddyConfigurationError == nil, "unreadable \(file.fileName) does not block independent Caddy work")
                }
                check(try Data(contentsOf: directory.appendingPathComponent(file.fileName)) == corrupt, "publication leaves unreadable storage untouched")
            }

            // A genuinely empty store is valid: deleting the last route must still publish.
            let empty = SiteStore(dataDirectory: root.appendingPathComponent("empty"), defaults: AppSettings(), runOneTimeMigrations: false)
            var publishedCounts: [Int] = []
            let controller = ProcessController(applyTunnel: { _, routes, _, _, _, _ in publishedCounts.append(routes.count); return "Applied" })
            controller.applyTunnels(store: empty, push: true)
            for _ in 0..<100 where controller.isServiceBusy("Cloudflared") { try? await Task.sleep(for: .milliseconds(5)) }
            check(publishedCounts == [0], "a readable empty store can publish removal of the last route")
        } catch { check(false, "storage apply fixtures: \(error)") }

        // Saving unchanged content keeps the backup of the real previous version.
        do {
            let file = root.appendingPathComponent("editor/editable.conf").path
            try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "v1".write(toFile: file, atomically: true, encoding: .utf8)
            let backup = ConfigurationService.backupPath(for: file)
            check(backup.hasPrefix(root.path + "/"), "fixture backup stays inside the temporary directory")
            let service = ConfigurationService(command: { _, _ in .init(status: 0, output: "") }, reload: { _ in })
            var applies = 0
            try await service.save(content: "v2", path: file, apply: { _ in applies += 1 })
            try await service.save(content: "v2", path: file, apply: { _ in applies += 1 })
            check(try String(contentsOfFile: backup, encoding: .utf8) == "v1", "saving unchanged content keeps the previous version as the backup")
            check(applies == 2, "saving unchanged content still applies it")
            do {
                try await service.save(content: "v2", path: file, apply: { _ in throw ConfigurationFailure("rejected") })
                check(false, "a rejected apply of unchanged content still throws")
            } catch {
                check(try String(contentsOfFile: file, encoding: .utf8) == "v2", "a rejected apply of unchanged content leaves the file")
            }
        } catch { check(false, "unchanged save fixtures: \(error)") }

        // Staged validation redirects only the exact live support paths.
        do {
            let config = root.appendingPathComponent("etc").path
            let renderer = ConfigRenderer(configDirectory: config, frankenphpLogPath: "")
            try renderer.writeAll(sites: [])
            let sibling = config + "2/extra.caddy"
            try fm.createDirectory(atPath: config + "2", withIntermediateDirectories: true)
            try "# sibling".write(toFile: sibling, atomically: true, encoding: .utf8)
            try "# other".write(toFile: config + "/other.caddy", atomically: true, encoding: .utf8)
            let override = config + "/overrides/custom.caddy"
            try "# old".write(toFile: override, atomically: true, encoding: .utf8)
            let edited = "import \(config)/other.caddy\nimport \(sibling)\nimport \(config)/snippets/php-app\n"
            var validated = "", stagedOverride = ""
            let service = ConfigurationService(command: { _, arguments in
                validated = (try? String(contentsOfFile: arguments[2], encoding: .utf8)) ?? ""
                // The staging directory is the one the validated Caddyfile imports overrides from.
                if let line = validated.split(separator: "\n").first(where: { $0.contains("/overrides/*.caddy") }),
                   let start = line.firstIndex(of: "\""), let end = line.lastIndex(of: "\""), start < end {
                    let stagedDirectory = String(line[line.index(after: start)..<end]).replacingOccurrences(of: "/overrides/*.caddy", with: "")
                    stagedOverride = (try? String(contentsOfFile: stagedDirectory + "/overrides/custom.caddy", encoding: .utf8)) ?? ""
                }
                return .init(status: 0, output: "")
            })
            var settings = AppSettings(caddyConfigDirectory: config)
            settings.runtimePaths.frankenphpBinary = "/test/frankenphp"
            _ = try await service.saveCaddySupport(content: edited, path: override, settings: settings, running: false)
            check(!validated.isEmpty && !validated.contains("\"\(config)/snippets/*\"") && !validated.contains("\"\(config)/overrides/"),
                  "validation imports staged snippets and overrides")
            check(stagedOverride.contains("import \(config)/other.caddy\n"), "other files in the config directory stay live")
            check(stagedOverride.contains("import \(sibling)\n"), "a sibling directory sharing the prefix is not rewritten")
            check(!stagedOverride.isEmpty && !stagedOverride.contains("import \(config)/snippets/"), "the staged snippets directory is used")
            check(try String(contentsOfFile: override, encoding: .utf8) == edited, "a validated support file is saved")
        } catch { check(false, "staged validation fixtures: \(error)") }
        return (passed, failed)
    }
}
