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
        return (passed, failed)
    }
}
