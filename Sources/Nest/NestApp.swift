import SwiftUI
import AppKit
import ObjectiveC
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
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        Window("Nest", id: MainWindowScene.id) {
            MainWindowSceneView(
                appDelegate: appDelegate,
                store: store,
                processController: processController,
                updaterController: updaterController
            )
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
                    AppDelegate.refreshWindowCorners()
                }
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

        Self.swizzleWindowCornerRadius(6.0)
        NSApp.setActivationPolicy(.regular)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
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

    static func swizzleWindowCornerRadius(_ radius: CGFloat) {
        guard let cls = NSClassFromString("NSThemeFrame") else { return }

        if let m = class_getInstanceMethod(cls, NSSelectorFromString("_cornerRadius")) {
            let block: @convention(block) (AnyObject) -> CGFloat = { _ in radius }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        if let m = class_getInstanceMethod(cls, NSSelectorFromString("_getCachedWindowCornerRadius")) {
            let block: @convention(block) (AnyObject) -> CGFloat = { _ in radius }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        if let m = class_getInstanceMethod(cls, NSSelectorFromString("_topCornerSize")) {
            let block: @convention(block) (AnyObject) -> CGSize = { _ in CGSize(width: radius, height: radius) }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        if let m = class_getInstanceMethod(cls, NSSelectorFromString("_bottomCornerSize")) {
            let block: @convention(block) (AnyObject) -> CGSize = { _ in CGSize(width: radius, height: radius) }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        if let m = class_getInstanceMethod(cls, NSSelectorFromString("_cornerPath")) {
            let block: @convention(block) (AnyObject) -> CGPath = { obj in
                let view = obj as! NSView
                return CGPath(roundedRect: view.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        if let m = class_getInstanceMethod(cls, NSSelectorFromString("_getCachedWindowCornerPath")) {
            let block: @convention(block) (AnyObject) -> CGPath = { obj in
                let view = obj as! NSView
                return CGPath(roundedRect: view.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    static func refreshWindowCorners() {
        for window in NSApp.windows {
            guard let frameView = window.contentView?.superview else { continue }
            let sel = NSSelectorFromString("windowCornerMaskChanged")
            if frameView.responds(to: sel) {
                frameView.perform(sel)
            }
            let sel2 = NSSelectorFromString("_updateCornerInsets")
            if frameView.responds(to: sel2) {
                frameView.perform(sel2)
            }
            window.display()
            window.invalidateShadow()
        }
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
            let renderer = ConfigRenderer(configDirectory: store.settings.caddyConfigDirectory, frankenphpLogPath: paths.frankenphpLog)
            try? renderer.writeAll(sites: store.sites)
            pc.startFrankenPHP(binary: paths.frankenphpBinary, caddyfilePath: renderer.caddyfilePath)
        }
        if !pc.cloudflaredRunning && !paths.cloudflaredBinary.isEmpty && store.settings.cloudflareSettings.hasLocalConfiguration {
            let renderer = TunnelConfigRenderer(settings: store.settings.cloudflareSettings)
            try? renderer.writeConfig(routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects)
            pc.startCloudflared(settings: store.settings)
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

    @objc func toggleCloudflared() {
        guard let pc = processController, let store else { return }
        if pc.cloudflaredRunning {
            pc.stopCloudflared()
        } else {
            let renderer = TunnelConfigRenderer(settings: store.settings.cloudflareSettings)
            try? renderer.writeConfig(routes: store.tunnelRoutes, sites: store.sites, projects: store.appProjects)
            pc.startCloudflared(settings: store.settings)
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
