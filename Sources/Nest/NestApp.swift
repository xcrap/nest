import SwiftUI
import NestLib
import ServiceManagement

@main
struct NestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SiteStore()
    @StateObject private var processController = ProcessController()

    var body: some Scene {
        Window("Nest", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(processController)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    appDelegate.store = store
                    appDelegate.processController = processController
                    appDelegate.setupStatusBar()
                    UpdateChecker.checkInBackground()
                }
        }
        .defaultSize(width: 960, height: 640)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate (Menu Bar + Window Management)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var store: SiteStore?
    var processController: ProcessController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func setupStatusBar() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Nest")
            button.image?.size = NSSize(width: 16, height: 16)
        }
        buildMenu()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.buildMenu()
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        let phpRunning = processController?.frankenphpRunning ?? false
        let dbRunning = processController?.mariadbRunning ?? false

        let phpItem = NSMenuItem(title: "FrankenPHP: \(phpRunning ? "Running" : "Stopped")", action: nil, keyEquivalent: "")
        phpItem.image = NSImage(systemSymbolName: phpRunning ? "circle.fill" : "circle", accessibilityDescription: nil)
        phpItem.image?.isTemplate = true
        menu.addItem(phpItem)

        let dbItem = NSMenuItem(title: "MariaDB: \(dbRunning ? "Running" : "Stopped")", action: nil, keyEquivalent: "")
        dbItem.image = NSImage(systemSymbolName: dbRunning ? "circle.fill" : "circle", accessibilityDescription: nil)
        dbItem.image?.isTemplate = true
        menu.addItem(dbItem)

        menu.addItem(.separator())

        if phpRunning || dbRunning {
            let stopAll = NSMenuItem(title: "Stop All Services", action: #selector(stopAllServices), keyEquivalent: "")
            stopAll.target = self
            menu.addItem(stopAll)
        }
        if !phpRunning || !dbRunning {
            let startAll = NSMenuItem(title: "Start All Services", action: #selector(startAllServices), keyEquivalent: "")
            startAll.target = self
            menu.addItem(startAll)
        }

        menu.addItem(.separator())

        let phpToggle = NSMenuItem(title: phpRunning ? "Stop FrankenPHP" : "Start FrankenPHP", action: #selector(toggleFrankenPHP), keyEquivalent: "")
        phpToggle.target = self
        menu.addItem(phpToggle)

        let dbToggle = NSMenuItem(title: dbRunning ? "Stop MariaDB" : "Start MariaDB", action: #selector(toggleMariaDB), keyEquivalent: "")
        dbToggle.target = self
        menu.addItem(dbToggle)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Nest", action: #selector(showMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Nest", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Nest" }) {
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func stopAllServices() {
        processController?.stopFrankenPHP()
        processController?.stopMariaDB()
    }

    @objc func startAllServices() {
        guard let store, let pc = processController else { return }
        let paths = store.settings.runtimePaths
        if !pc.frankenphpRunning && !paths.frankenphpBinary.isEmpty {
            let renderer = ConfigRenderer(configDirectory: store.settings.caddyConfigDirectory, frankenphpLogPath: paths.frankenphpLog)
            try? renderer.writeAll(sites: store.sites)
            pc.startFrankenPHP(binary: paths.frankenphpBinary, caddyfilePath: renderer.caddyfilePath)
        }
        if !pc.mariadbRunning && !paths.mariadbServer.isEmpty {
            pc.startMariaDB(serverBinary: paths.mariadbServer)
        }
    }

    @objc func toggleFrankenPHP() {
        guard let pc = processController, let store else { return }
        if pc.frankenphpRunning {
            pc.stopFrankenPHP()
        } else {
            let paths = store.settings.runtimePaths
            let renderer = ConfigRenderer(configDirectory: store.settings.caddyConfigDirectory, frankenphpLogPath: paths.frankenphpLog)
            try? renderer.writeAll(sites: store.sites)
            pc.startFrankenPHP(binary: paths.frankenphpBinary, caddyfilePath: renderer.caddyfilePath)
        }
    }

    @objc func toggleMariaDB() {
        guard let pc = processController, let store else { return }
        if pc.mariadbRunning {
            pc.stopMariaDB()
        } else {
            pc.startMariaDB(serverBinary: store.settings.runtimePaths.mariadbServer)
        }
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}

// MARK: - Auto Updater

enum UpdateChecker {
    static func checkInBackground() {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        Task.detached {
            guard let url = URL(string: "https://api.github.com/repos/xcrap/nest/releases/latest") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else { return }
            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            guard latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending else { return }

            // Find the DMG asset URL
            guard let assets = json["assets"] as? [[String: Any]],
                  let dmgAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                  let downloadURL = dmgAsset["browser_download_url"] as? String else { return }

            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Update Available"
                alert.informativeText = "Nest \(latestVersion) is available. You're running \(currentVersion).\n\nUpdate and relaunch automatically?"
                alert.addButton(withTitle: "Update Now")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    performUpdate(downloadURL: downloadURL)
                }
            }
        }
    }

    @MainActor
    private static func performUpdate(downloadURL: String) {
        guard let url = URL(string: downloadURL) else { return }
        let appPath = Bundle.main.bundlePath

        // Show progress
        let progressAlert = NSAlert()
        progressAlert.messageText = "Updating Nest..."
        progressAlert.informativeText = "Downloading update. Please wait."
        progressAlert.addButton(withTitle: "")
        progressAlert.buttons.first?.isHidden = true
        let window = progressAlert.window
        progressAlert.layout()

        // Show non-modally
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)

        Task.detached {
            do {
                // Download DMG
                let (dmgFileURL, _) = try await URLSession.shared.download(from: url)
                let tmpDMG = FileManager.default.temporaryDirectory.appendingPathComponent("NestUpdate.dmg")
                try? FileManager.default.removeItem(at: tmpDMG)
                try FileManager.default.moveItem(at: dmgFileURL, to: tmpDMG)

                // Mount DMG
                let mountProcess = Process()
                mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                mountProcess.arguments = ["attach", tmpDMG.path, "-nobrowse", "-quiet", "-mountpoint", "/tmp/NestUpdate"]
                let mountPipe = Pipe()
                mountProcess.standardOutput = mountPipe
                mountProcess.standardError = FileHandle.nullDevice
                try mountProcess.run()
                mountProcess.waitUntilExit()

                guard mountProcess.terminationStatus == 0 else {
                    await MainActor.run { window.close() }
                    return
                }

                // Copy new app over current
                let srcApp = "/tmp/NestUpdate/Nest.app"
                guard FileManager.default.fileExists(atPath: srcApp) else {
                    await MainActor.run { window.close() }
                    return
                }

                // Write a script that waits for us to quit, replaces the app, and relaunches
                let script = """
                #!/bin/bash
                sleep 1
                rm -rf "\(appPath)"
                cp -R "\(srcApp)" "\(appPath)"
                hdiutil detach /tmp/NestUpdate -quiet 2>/dev/null
                rm -f "\(tmpDMG.path)"
                open "\(appPath)"
                rm -f /tmp/nest-update.sh
                """
                try script.write(toFile: "/tmp/nest-update.sh", atomically: true, encoding: .utf8)

                let chmod = Process()
                chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
                chmod.arguments = ["+x", "/tmp/nest-update.sh"]
                try chmod.run()
                chmod.waitUntilExit()

                // Launch the updater script and quit
                let updater = Process()
                updater.executableURL = URL(fileURLWithPath: "/bin/bash")
                updater.arguments = ["/tmp/nest-update.sh"]
                try updater.run()

                await MainActor.run {
                    window.close()
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    window.close()
                    let errAlert = NSAlert()
                    errAlert.messageText = "Update Failed"
                    errAlert.informativeText = error.localizedDescription
                    errAlert.runModal()
                }
            }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Launch Nest at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    do {
                        if newValue { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 100)
    }
}
