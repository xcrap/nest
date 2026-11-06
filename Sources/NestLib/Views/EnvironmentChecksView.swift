import SwiftUI
import AppKit

/// The last completed run, kept across view instances so switching tabs or re-activating the
/// app shows it at once and only re-runs the checks once it is stale.
@MainActor
private enum EnvironmentCheckCache {
    static var checks: [PrerequisiteChecker.CheckResult] = []
    static var helperStatus: PFHelperStatus = .unsupported
    static var completedAt: Date?
}

public struct EnvironmentChecksView: View {
    /// Automatic re-runs (appearing, app activation) are skipped within this window; an
    /// explicit Recheck or a state change Nest caused always runs.
    static let automaticRecheckInterval: TimeInterval = 30

    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController
    @State private var checkTask: Task<Void, Never>?
    @State private var delayedRecheck: Task<Void, Never>?
    @State private var recheckRequested = false
    @State private var checks: [PrerequisiteChecker.CheckResult] = EnvironmentCheckCache.checks
    @State private var helperStatus: PFHelperStatus = EnvironmentCheckCache.helperStatus
    @State private var helperMessage: String?
    @State private var confirmUninstall = false

    private var isChecking: Bool { checkTask != nil }
    // Path validation is a few stat calls, so it always reflects the current settings.
    private var runtimeIssues: [String] { store.settings.runtimePaths.validate() }
    private var optionalRuntimeIssues: [String] { store.settings.runtimePaths.optionalIssues() }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Spacer()
                    if isChecking {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { runChecks(force: true) }
                    } label: {
                        Label("Recheck", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isChecking)
                }

                sectionCard(title: "Services", icon: "play.circle.fill", color: .green) {
                    VStack(spacing: 4) {
                        serviceControl(
                            name: "FrankenPHP", icon: "bolt.fill",
                            running: processController.frankenphpRunning,
                            error: processController.frankenphpError,
                            onStart: { startFrankenPHP() },
                            onStop: { processController.stopFrankenPHP() }
                        )
                        serviceControl(
                            name: "Cloudflared", icon: "network",
                            running: processController.cloudflaredRunning,
                            error: processController.cloudflaredError,
                            onStart: { startCloudflared() },
                            onStop: { processController.stopCloudflared() }
                        )
                        serviceControl(
                            name: "MariaDB", icon: "cylinder.fill",
                            running: processController.mariadbRunning,
                            error: processController.mariadbError,
                            onStart: { startMariaDB() },
                            onStop: { processController.stopMariaDB() }
                        )
                    }
                }

                sectionCard(title: "Runtime Binaries", icon: "wrench.and.screwdriver.fill", color: .purple) {
                    ForEach(optionalRuntimeIssues, id: \.self) { issue in
                        Label(issue, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if runtimeIssues.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("All runtime paths are valid.")
                                .font(.callout)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(runtimeIssues, id: \.self) { issue in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.callout)
                                    Text(issue)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !store.persistenceErrors.isEmpty {
                    sectionCard(title: "Storage", icon: "externaldrive.badge.exclamationmark", color: .orange) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(store.persistenceErrors, id: \.self) { issue in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.callout)
                                    Text(issue)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                sectionCard(title: "System Prerequisites", icon: "shield.checkered", color: .blue) {
                    VStack(spacing: 4) {
                        if checks.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking system prerequisites…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        ForEach(checks) { check in
                            prerequisiteRow(check)
                        }
                    }
                    .opacity(isChecking && !checks.isEmpty ? 0.6 : 1)
                }
            }
            .padding(16)
        }
        .onAppear { runChecks(force: false) }
        .onDisappear {
            checkTask?.cancel()
            checkTask = nil
            delayedRecheck?.cancel()
            delayedRecheck = nil
            recheckRequested = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            runChecks(force: false)
        }
        // Redirect and CA results depend on FrankenPHP; refresh them when it starts or stops.
        .onChange(of: processController.frankenphpRunning) { runChecks(force: true) }
        .alert("Uninstall the Nest Helper?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { uninstallPFHelper() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ports 80 and 443 will stop redirecting to FrankenPHP after the next restart, and .test sites will need the port in their URL.")
        }
    }

    // MARK: - Components

    private func sectionCard(title: String, icon: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(color)
                    .frame(width: 20, height: 20)
                    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func serviceControl(
        name: String, icon: String, running: Bool, error: String?,
        onStart: @escaping () -> Void, onStop: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(running ? .green : .secondary)
                    .frame(width: 16)

                Text(name)
                    .font(.callout)
                    .fontWeight(.medium)

                HStack(spacing: 5) {
                    Circle()
                        .fill(running ? Color.green : Color.secondary.opacity(0.2))
                        .frame(width: 6, height: 6)
                    Text(running ? "Running" : "Stopped")
                        .font(.callout)
                        .foregroundStyle(running ? .green : .secondary)
                }

                Spacer()

                Button(running ? "Stop" : "Start") {
                    if running { onStop() } else { onStart() }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(running ? .red : .green)
                .disabled(processController.isServiceBusy(name))
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 8)
    }

    private func prerequisiteRow(_ check: PrerequisiteChecker.CheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon(for: check))
                    .foregroundStyle(color(for: check))
                    .font(.callout)
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.name)
                        .font(.callout)
                        .fontWeight(.medium)
                    Text(check.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if check.action != .none {
                    actionButton(for: check.action)
                }
                // Repair/Uninstall only make sense once the helper is registered; the check's own
                // action already offers Repair when the redirect is broken.
                if check.id == .pfAnchor, [.enabled, .requiresApproval].contains(helperStatus) {
                    if helperStatus == .enabled, check.action != .repairPFHelper {
                        Button("Repair") { repairPFHelper() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button("Uninstall…") { confirmUninstall = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if !check.passed && !check.fixHint.isEmpty {
                Text(check.fixHint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .padding(.leading, 24)
            }
            if !check.fixCommands.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(check.fixCommands, id: \.self) { command in
                        HStack(spacing: 8) {
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Spacer()
                            Button {
                                copy(command)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Copy command")
                        }
                    }
                }
                .padding(.leading, 24)
            }
            if let helperMessage, check.id == .pfAnchor {
                Text(helperMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 6)
    }

    private func icon(for check: PrerequisiteChecker.CheckResult) -> String {
        if check.passed { return "checkmark.circle.fill" }
        switch check.severity {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private func color(for check: PrerequisiteChecker.CheckResult) -> Color {
        if check.passed { return .green }
        switch check.severity {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    @ViewBuilder
    private func actionButton(for action: PrerequisiteChecker.CheckAction) -> some View {
        switch action {
        case .installPFHelper:
            Button("Install Helper") { installPFHelper() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .repairPFHelper:
            Button("Repair") { repairPFHelper() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .uninstallPFHelper:
            Button("Uninstall…") { confirmUninstall = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .openPFHelperSettings:
            Button("Open Settings") { PFHelperManager.openLoginItemsSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Actions

    /// Checks launch several processes (dig, curl, pgrep, security), so automatic triggers reuse a
    /// recent result. A request while a run is in flight schedules one follow-up run instead of
    /// stacking another.
    private func runChecks(force: Bool) {
        if !force, let completedAt = EnvironmentCheckCache.completedAt, !checks.isEmpty,
           Date().timeIntervalSince(completedAt) < Self.automaticRecheckInterval {
            return
        }
        guard checkTask == nil else {
            if force { recheckRequested = true }
            return
        }
        checkTask = Task {
            let result = await BlockingWork.run(qos: .userInitiated) { () -> ([PrerequisiteChecker.CheckResult], PFHelperStatus) in
                let status = PFHelperManager.status
                return (PrerequisiteChecker.checkAll(pfHelperStatus: status), status)
            }
            // A cancelled run was already detached from checkTask by onDisappear.
            guard !Task.isCancelled else { return }
            checkTask = nil
            checks = result.0
            helperStatus = result.1
            EnvironmentCheckCache.checks = result.0
            EnvironmentCheckCache.helperStatus = result.1
            EnvironmentCheckCache.completedAt = Date()
            if recheckRequested {
                recheckRequested = false
                runChecks(force: true)
            }
        }
    }

    private func installPFHelper() {
        do {
            try PFHelperManager.register()
            switch PFHelperManager.status {
            case .enabled:
                helperMessage = "Helper installed. Ports 80/443 will redirect automatically on every boot."
            case .requiresApproval:
                helperMessage = "Approve the helper in System Settings → General → Login Items & Extensions."
                PFHelperManager.openLoginItemsSettings()
            case .notFound:
                helperMessage = "Helper plist missing from app bundle. Reinstall Nest."
            case .notRegistered, .unknown, .unsupported:
                helperMessage = "Helper registration didn't take effect. Try again or reinstall Nest."
            }
        } catch {
            helperMessage = "Helper install failed: \(error.localizedDescription)"
        }
        runChecks(force: true)
    }

    private func repairPFHelper() {
        if PFHelperManager.repair() {
            helperMessage = "Helper repair requested. Checks will refresh in a few seconds."
        } else {
            helperMessage = "Helper repair could not be requested. Install or approve the helper first."
        }
        // launchd throttles the helper to one run every 5 seconds. The wait is cancelled with
        // the view, so a closed tab never re-runs checks behind the user's back.
        delayedRecheck?.cancel()
        delayedRecheck = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            delayedRecheck = nil
            runChecks(force: true)
        }
    }

    private func uninstallPFHelper() {
        do {
            try PFHelperManager.unregister()
            let helperPath = (Bundle.main.bundlePath as NSString)
                .appendingPathComponent("Contents/MacOS/NestPFHelper")
            helperMessage = "Helper unregistered. To remove existing PF files, run: sudo \"\(helperPath)\" --uninstall"
        } catch {
            helperMessage = "Helper uninstall failed: \(error.localizedDescription)"
        }
        runChecks(force: true)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func startFrankenPHP() {
        processController.startFrankenPHP(store: store)
    }

    private func startMariaDB() {
        processController.startMariaDB(serverBinary: store.settings.runtimePaths.mariadbServer)
    }

    private func startCloudflared() {
        processController.applyTunnels(store: store, start: true)
    }

}
