import SwiftUI
import AppKit
import Combine
import NestLib
import ServiceManagement
import Sparkle

private enum MainWindowScene {
    static let id = "main-window"
}

@main
struct NestApp: App {
    /// The delegate owns the app's state, so the menu bar item, launch checks and wake
    /// handling work even when the main window is never shown.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Nest", id: MainWindowScene.id) {
            MainWindowSceneView(appDelegate: appDelegate)
        }
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            SectionCommands()
        }

        Settings {
            SettingsView(updater: appDelegate.updaterController.updater)
        }
    }
}

private struct MainWindowSceneView: View {
    @Environment(\.openWindow) private var openWindow

    let appDelegate: AppDelegate

    var body: some View {
        ContentView(processController: appDelegate.processController)
            .environmentObject(appDelegate.store)
            .environmentObject(appDelegate.processController)
            .environmentObject(appDelegate.configDocuments)
            .environment(\.actionProcessController, appDelegate.processController)
            .frame(minWidth: 800, minHeight: 500)
            .onAppear {
                appDelegate.openMainWindowAction = openWindow
            }
    }
}

// MARK: - App Delegate (Menu Bar + Window Management)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Created on first use (window or launch setup), not when the delegate is constructed.
    lazy var store = SiteStore()
    let processController = ProcessController()
    let configDocuments = ConfigDocumentStore()
    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: AppSettings.reviewDirectory == nil,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    var statusItem: NSStatusItem?
    var openMainWindowAction: OpenWindowAction?
    private let statusMenu = NSMenu()
    private var statusTimer: Timer?
    private var statusObservation: AnyCancellable?
    private var didReconcileNetwork = false
    private var didFinishSetup = false

    /// Runs the PF/DNS check once per launch; it must not repeat (a broken redirect can
    /// trigger an administrator prompt).
    func reconcileNetworkAtLaunchIfNeeded() {
        guard !didReconcileNetwork else { return }
        didReconcileNetwork = true
        DispatchQueue.main.async { [weak self] in
            self?.processController.reconcileSystemNetworkState()
        }
    }

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
        guard !didFinishSetup else { return }
        didFinishSetup = true

        _ = updaterController
        setupStatusBar()
        reconcileNetworkAtLaunchIfNeeded()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard didFinishSetup else { return .terminateNow }
        var unsaved: [String] = []
        if configDocuments.hasDirtyEditors { unsaved.append("Settings → Config") }
        if configDocuments.hasUnsavedRuntimePaths(comparedTo: store.settings.runtimePaths) { unsaved.append("Settings → Paths") }
        if let draft = configDocuments.cloudflareDraft,
           NestValidation.normalizedCloudflareSettings(draft) != store.settings.cloudflareSettings {
            unsaved.append("Settings → Cloudflare")
        }
        guard !unsaved.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved configuration changes?"
        alert.informativeText = "You have unsaved changes in \(ListFormatter.localizedString(byJoining: unsaved)). Return there to save them."
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
        statusMenu.delegate = self
        statusItem?.menu = statusMenu
        buildMenu()
        refreshStatus()
        // Rebuild when status changes (also while the menu is open); coalesced to one pass per change burst.
        statusObservation = processController.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.buildMenu() }
        // Poll only while a Nest window is on screen; the menu refreshes itself when opened.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isMainWindowVisible else { return }
                self.refreshStatus()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    private var isMainWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && $0.title == "Nest" }
    }

    private func refreshStatus() {
        processController.refreshStatusSnapshot(settings: store.settings, projects: store.appProjects)
    }

    @objc private func applicationBecameActive() {
        refreshStatus()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu()
        refreshStatus()
    }

    private var serviceErrors: [(service: String, message: String)] {
        [("FrankenPHP", processController.frankenphpError),
         ("MariaDB", processController.mariadbError),
         ("Cloudflared", processController.cloudflaredError)]
            .compactMap { (service: String, message: String?) -> (service: String, message: String)? in
                guard let message, !message.isEmpty else { return nil }
                return (service, message)
            }
    }

    /// Monochrome template icon: filled while any service runs, outlined when all are stopped.
    private func updateStatusIcon(anyRunning: Bool) {
        guard let button = statusItem?.button else { return }
        let errors = serviceErrors
        let state = anyRunning ? "services running" : "services stopped"
        let description = errors.isEmpty ? "Nest, \(state)" : "Nest, \(state), \(errors.count) error\(errors.count == 1 ? "" : "s")"
        let symbol = NSImage(systemSymbolName: anyRunning ? "bird.fill" : "bird", accessibilityDescription: description)
            ?? NSImage(systemSymbolName: anyRunning ? "circle.fill" : "circle", accessibilityDescription: description)
        let image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)) ?? symbol
        image?.isTemplate = true
        button.image = image
        button.toolTip = errors.isEmpty
            ? "Nest: \(state)"
            : "Nest: \(state)\n" + errors.map { "\($0.service): \($0.message)" }.joined(separator: "\n")
    }

    private func addStatusItem(_ name: String, running: Bool, error: String?, to menu: NSMenu) {
        let item = NSMenuItem(title: "\(name): \(running ? "Running" : "Stopped")", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: running ? "circle.fill" : "circle", accessibilityDescription: nil)
        item.image?.isTemplate = true
        menu.addItem(item)

        guard let error, !error.isEmpty else { return }
        // A failed start must be visible even when the window is closed.
        let firstLine = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
        let title = firstLine.count > 80 ? String(firstLine.prefix(79)) + "…" : firstLine
        let errorItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        errorItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Error")
        errorItem.image?.isTemplate = true
        errorItem.indentationLevel = 1
        errorItem.toolTip = error
        errorItem.isEnabled = false
        menu.addItem(errorItem)
    }

    func buildMenu() {
        let menu = statusMenu
        menu.removeAllItems()
        let phpRunning = processController.frankenphpRunning
        let dbRunning = processController.mariadbRunning
        let cloudflaredRunning = processController.cloudflaredRunning
        updateStatusIcon(anyRunning: phpRunning || dbRunning || cloudflaredRunning)

        addStatusItem("FrankenPHP", running: phpRunning, error: processController.frankenphpError, to: menu)
        addStatusItem("MariaDB", running: dbRunning, error: processController.mariadbError, to: menu)
        addStatusItem("Cloudflared", running: cloudflaredRunning, error: processController.cloudflaredError, to: menu)

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
        updaterController.checkForUpdates(nil)
    }

    @objc func stopAllServices() {
        processController.stopFrankenPHP()
        processController.stopCloudflared()
        processController.stopMariaDB()
    }

    @objc func startAllServices() {
        let pc = processController
        let paths = store.settings.runtimePaths
        if !pc.frankenphpRunning && !paths.frankenphpBinary.isEmpty {
            pc.startFrankenPHP(store: store)
        }
        if !pc.cloudflaredRunning && !paths.cloudflaredBinary.isEmpty && store.settings.cloudflareSettings.hasLocalConfiguration {
            pc.applyTunnels(store: store, start: true)
        }
        if !pc.mariadbRunning && !paths.mariadbServer.isEmpty {
            pc.startMariaDB(serverBinary: paths.mariadbServer)
        }
    }

    @objc func toggleFrankenPHP() {
        if processController.frankenphpRunning {
            processController.stopFrankenPHP()
        } else {
            processController.startFrankenPHP(store: store)
        }
    }

    @objc func toggleMariaDB() {
        if processController.mariadbRunning {
            processController.stopMariaDB()
        } else {
            processController.startMariaDB(serverBinary: store.settings.runtimePaths.mariadbServer)
        }
    }

    @objc func toggleCloudflared() {
        if processController.cloudflaredRunning {
            processController.stopCloudflared()
        } else {
            processController.applyTunnels(store: store, start: true)
        }
    }

    @objc func handleSystemWake() {
        // Delay to let network stack stabilize after wake
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.processController.handleSystemWake()
        }
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}

// MARK: - Settings View

struct SettingsView: View {
    let updater: SPUUpdater
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var autoUpdate = true

    /// On while registered, including while macOS waits for the user's approval.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
            set: { setLaunchAtLogin($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch Nest at login", isOn: launchAtLogin)

                if loginStatus == .requiresApproval {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Allow Nest in System Settings → General → Login Items to finish turning this on.", systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }

            Section {
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
        }
        .formStyle(.grouped)
        .frame(width: 440, height: loginStatus == .requiresApproval || loginError != nil ? 280 : 200)
        .onAppear { loginStatus = SMAppService.mainApp.status }
        // The user may approve (or remove) the login item in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = enabled
                ? "Could not turn on launch at login: \(error.localizedDescription)"
                : "Could not turn off launch at login: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
        // Registration that needs approval is reported by the status, not as a failure.
        if loginStatus == .requiresApproval { loginError = nil }
    }
}
