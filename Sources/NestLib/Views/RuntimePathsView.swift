import SwiftUI

public struct RuntimePathsView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var documents: ConfigDocumentStore
    @State private var validationIssues: [String] = []
    @State private var optionalIssues: [String] = []
    @State private var saved = false
    @State private var detected = false
    @State private var detecting = false
    @State private var validated = false

    public init() {}

    /// Edits (and Auto-Detect results) live in the shared document store until saved, so
    /// they survive tab switches and are covered by the quit check.
    private var paths: Binding<RuntimePaths> {
        Binding(
            get: { documents.runtimePathsDraft ?? store.settings.runtimePaths },
            set: { documents.runtimePathsDraft = $0 }
        )
    }

    private var hasUnsavedChanges: Bool {
        documents.hasUnsavedRuntimePaths(comparedTo: store.settings.runtimePaths)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    settingsCard(title: "FrankenPHP", icon: "bolt.fill", color: .purple) {
                        VStack(spacing: 12) {
                            pathRow("Binary", section: "FrankenPHP", path: paths.frankenphpBinary)
                            pathRow("php.ini", section: "FrankenPHP", path: paths.phpIniPath)
                            pathRow("Log File", section: "FrankenPHP", path: paths.frankenphpLog)
                        }
                    }

                    settingsCard(title: "MariaDB", icon: "cylinder.fill", color: .blue) {
                        VStack(spacing: 12) {
                            pathRow("Server (mariadbd)", section: "MariaDB", path: paths.mariadbServer)
                            pathRow("Client (mariadb)", section: "MariaDB", path: paths.mariadbClient)
                            pathRow("mysqldump", section: "MariaDB", path: paths.mysqldump)
                            pathRow("Log File", section: "MariaDB", path: paths.mariadbLog)
                        }
                    }

                    settingsCard(title: "Cloudflared", icon: "network", color: .green) {
                        VStack(spacing: 12) {
                            pathRow("Binary", section: "Cloudflared", path: paths.cloudflaredBinary)
                            pathRow("Log File", section: "Cloudflared", path: paths.cloudflaredLog)
                        }
                    }

                    if !validationIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(validationIssues, id: \.self) { issue in
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.callout)
                                        .accessibilityHidden(true)
                                    Text(issue)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.orange.opacity(0.06))
                                .strokeBorder(Color.orange.opacity(0.15), lineWidth: 1)
                        )
                    }

                    if !optionalIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(optionalIssues, id: \.self) { issue in
                                Label(issue, systemImage: "info.circle")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack(spacing: 8) {
                if hasUnsavedChanges {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if detected {
                    Label("Detected", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                if validated {
                    Label("Valid", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
                }
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Spacer()

                if hasUnsavedChanges {
                    Button("Revert") {
                        documents.runtimePathsDraft = nil
                        validationIssues = []
                        validated = false
                        optionalIssues = store.settings.runtimePaths.optionalIssues()
                    }
                    .controlSize(.small)
                    .help("Discard unsaved path changes")
                }

                Button("Validate") {
                    let current = paths.wrappedValue
                    let issues = current.validate()
                    withAnimation {
                        validationIssues = issues
                        optionalIssues = current.optionalIssues()
                    }
                    validated = issues.isEmpty
                    saved = false
                }
                .controlSize(.small)

                Button {
                    detecting = true
                    let draft = paths
                    Task {
                        // Detection launches FrankenPHP to find php.ini; keep the UI responsive.
                        let detectedPaths = await BlockingWork.run(qos: .userInitiated) { RuntimePaths.detectDefaults() }
                        detecting = false
                        withAnimation(.easeInOut(duration: 0.2)) {
                            draft.wrappedValue = detectedPaths
                            detected = true
                        }
                        optionalIssues = detectedPaths.optionalIssues()
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { detected = false }
                    }
                } label: {
                    Label("Auto-Detect", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(detecting)

                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear {
            optionalIssues = paths.wrappedValue.optionalIssues()
        }
    }

    private func save() {
        let current = paths.wrappedValue
        let issues = current.validate()
        optionalIssues = current.optionalIssues()
        guard issues.isEmpty else {
            withAnimation {
                validationIssues = issues
                saved = false
            }
            return
        }

        // Keep the in-memory settings identical to disk if the save fails.
        let previous = store.settings.runtimePaths
        store.settings.runtimePaths = current
        guard store.saveSettings() else {
            store.settings.runtimePaths = previous
            validationIssues = [store.saveError(.settings) ?? "Could not save settings."]
            saved = false
            return
        }
        documents.runtimePathsDraft = nil
        withAnimation {
            validationIssues = []
            saved = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { saved = false }
        }
    }

    // MARK: - Components

    private func settingsCard(title: String, icon: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(color)
                    .frame(width: 20, height: 20)
                    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func pathRow(_ label: String, section: String, path: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                TextField("\(section) \(label) path", text: path)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowsMultipleSelection = false
                    panel.message = "Choose the \(section) \(label)"
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                    }
                }
                .controlSize(.small)
                .accessibilityLabel("Browse for \(section) \(label)")
            }
        }
    }
}
