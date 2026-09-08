import SwiftUI
import AppKit
import NestLib
import ServiceManagement
import Sparkle

private enum MainWindowScene {
    static let id = "main-window"
}

@main
struct NestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SiteStore()
    @StateObject private var processController = ProcessController()
    @StateObject private var configDocuments = ConfigDocumentStore()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: AppSettings.reviewDirectory == nil, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        Window("Nest", id: MainWindowScene.id) {
            MainWindowSceneView(
                appDelegate: appDelegate,
                store: store,
                processController: processController,
                updaterController: updaterController
            )
            .environmentObject(configDocuments)
            .onAppear { appDelegate.configDocuments = configDocuments }
        }
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
            }
        }

        Settings {
            SettingsView(updater: updaterController.updater)
        }
    }
}

private struct MainWindowSceneView: View {
    @Environment(\.openWindow) private var openWindow

    let appDelegate: AppDelegate
    let store: SiteStore
    let processController: ProcessController
    let updaterController: SPUStandardUpdaterController

    var body: some View {
        ContentView()
            .environmentObject(store)
            .environmentObject(processController)
            .frame(minWidth: 800, minHeight: 500)
            .onAppear {
                appDelegate.store = store
                appDelegate.processController = processController
                appDelegate.updaterController = updaterController
                appDelegate.openMainWindowAction = openWindow
                appDelegate.setupStatusBar()
                DispatchQueue.main.async {
                    processController.reconcileSystemNetworkState()
                }
            }
    }
}

// MARK: - App Delegate (Menu Bar + Window Management)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var configDocuments: ConfigDocumentStore?
    var statusItem: NSStatusItem?
    var store: SiteStore?
    var processController: ProcessController?
    var updaterController: SPUStandardUpdaterController?
    var openMainWindowAction: OpenWindowAction?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enforce single instance — dev and prod use different bundle IDs so they can coexist
        if let bundleID = Bundle.main.bundleIdentifier {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != currentPID }
            if let existing = others.first {
                existing.activate()
                NSApp.terminate(nil)
                return
            }
        }

        NSApp.setActivationPolicy(.regular)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard configDocuments?.drafts.values.contains(where: { $0.dirty }) == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved configuration changes?"
        alert.informativeText = "Your editor drafts have not been saved. Return to Settings → Config to save them."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard and Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

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
            Task { @MainActor in
                self?.buildMenu()
            }
        }
    }

    func buildMenu() {
        if let store, let processController {
            processController.refreshStatusSnapshot(settings: store.settings, projects: store.appProjects)
        }
        let menu = NSMenu()
        let phpRunning = processController?.frankenphpRunning ?? false
        let dbRunning = processController?.mariadbRunning ?? false
        let cloudflaredRunning = processController?.cloudflaredRunning ?? false

        let phpItem = NSMenuItem(title: "FrankenPHP: \(phpRunning ? "Running" : "Stopped")", action: nil, keyEquivalent: "")
        phpItem.image = NSImage(systemSymbolName: phpRunning ? "circle.fill" : "circle", accessibilityDescription: nil)
        phpItem.image?.isTemplate = true
        menu.addItem(phpItem)

        let dbItem = NSMenuItem(title: "MariaDB: \(dbRunning ? "Running" : "Stopped")", action: nil, keyEquivalent: "")
        dbItem.image = NSImage(systemSymbolName: dbRunning ? "circle.fill" : "circle", accessibilityDescription: nil)
        dbItem.image?.isTemplate = true
        menu.addItem(dbItem)

        let cloudflareItem = NSMenuItem(title: "Cloudflared: \(cloudflaredRunning ? "Running" : "Stopped")", action: nil, keyEquivalent: "")
        cloudflareItem.image = NSImage(systemSymbolName: cloudflaredRunning ? "circle.fill" : "circle", accessibilityDescription: nil)
        cloudflareItem.image?.isTemplate = true
        menu.addItem(cloudflareItem)

        menu.addItem(.separator())

        if phpRunning || dbRunning || cloudflaredRunning {
            let stopAll = NSMenuItem(title: "Stop All Services", action: #selector(stopAllServices), keyEquivalent: "")
            stopAll.target = self
            menu.addItem(stopAll)
        }
        if !phpRunning || !dbRunning || !cloudflaredRunning {
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

        let cloudflareToggle = NSMenuItem(title: cloudflaredRunning ? "Stop Cloudflared" : "Start Cloudflared", action: #selector(toggleCloudflared), keyEquivalent: "")
        cloudflareToggle.target = self
        menu.addItem(cloudflareToggle)

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
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?(id: MainWindowScene.id)
        }
    }

    @objc func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    @objc func stopAllServices() {
        processController?.stopFrankenPHP()
        processController?.stopCloudflared()
        processController?.stopMariaDB()
    }

    @objc func startAllServices() {
        guard let store, let pc = processController else { return }
        let paths = store.settings.runtimePaths
        if !pc.frankenphpRunning && !paths.frankenphpBinary.isEmpty {
            pc.startFrankenPHP(settings: store.settings, sites: store.sites)
        }
        if !pc.cloudflaredRunning && !paths.cloudflaredBinary.isEmpty && store.settings.cloudflareSettings.hasLocalConfiguration {
            pc.applyTunnels(settings: store.settings, routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects, start: true)
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
            pc.startFrankenPHP(settings: store.settings, sites: store.sites)
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

    @objc func toggleCloudflared() {
        guard let pc = processController, let store else { return }
        if pc.cloudflaredRunning {
            pc.stopCloudflared()
        } else {
            pc.applyTunnels(settings: store.settings, routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects, start: true)
        }
    }

    @objc func handleSystemWake() {
        // Delay to let network stack stabilize after wake
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.processController?.handleSystemWake()
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
                .onChange(of: launchAtLogin) {
                    do {
                        if launchAtLogin { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Toggle("Automatically check for updates", isOn: $autoUpdate)
                .onChange(of: autoUpdate) {
                    updater.automaticallyChecksForUpdates = autoUpdate
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
