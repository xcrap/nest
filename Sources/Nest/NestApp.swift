import SwiftUI
import NestLib
import ServiceManagement
import Sparkle

@main
struct NestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SiteStore()
    @StateObject private var processController = ProcessController()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        Window("Nest", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(processController)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    appDelegate.store = store
                    appDelegate.processController = processController
                    appDelegate.updaterController = updaterController
                    appDelegate.setupStatusBar()
                }
        }
        .defaultSize(width: 960, height: 640)

        Settings {
            SettingsView(updater: updaterController.updater)
        }
    }
}

// MARK: - App Delegate (Menu Bar + Window Management)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var store: SiteStore?
    var processController: ProcessController?
    var updaterController: SPUStandardUpdaterController?

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
            if let appIcon = NSImage(named: NSImage.applicationIconName) {
                let resized = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                    appIcon.draw(in: rect)
                    return true
                }
                resized.isTemplate = false
                button.image = resized
            }
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

        let checkUpdate = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdate.target = self
        menu.addItem(checkUpdate)

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

    @objc func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
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

// MARK: - Settings View

struct SettingsView: View {
    let updater: SPUUpdater
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoUpdate = true

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

            Toggle("Automatically check for updates", isOn: $autoUpdate)
                .onChange(of: autoUpdate) { newValue in
                    updater.automaticallyChecksForUpdates = newValue
                }
                .onAppear {
                    autoUpdate = updater.automaticallyChecksForUpdates
                }

            Button("Check for Updates Now…") {
                updater.checkForUpdates()
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 160)
    }
}
