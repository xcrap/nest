import SwiftUI

public struct RuntimePathsView: View {
    @EnvironmentObject var store: SiteStore
    @State private var paths: RuntimePaths = RuntimePaths()
    @State private var validationIssues: [String] = []
    @State private var saved = false
    @State private var detected = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    settingsCard(title: "FrankenPHP", icon: "bolt.fill", color: .purple) {
                        VStack(spacing: 12) {
                            pathRow("Binary", path: $paths.frankenphpBinary)
                            pathRow("php.ini", path: $paths.phpIniPath)
                            pathRow("Log File", path: $paths.frankenphpLog)
                        }
                    }

                    settingsCard(title: "MariaDB", icon: "cylinder.fill", color: .blue) {
                        VStack(spacing: 12) {
                            pathRow("Server (mariadbd)", path: $paths.mariadbServer)
                            pathRow("Client (mariadb)", path: $paths.mariadbClient)
                            pathRow("mysqldump", path: $paths.mysqldump)
                            pathRow("Log File", path: $paths.mariadbLog)
                        }
                    }

                    settingsCard(title: "Cloudflared", icon: "network", color: .green) {
                        VStack(spacing: 12) {
                            pathRow("Binary", path: $paths.cloudflaredBinary)
                            pathRow("Log File", path: $paths.cloudflaredLog)
                        }
                    }

                    if !validationIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(validationIssues, id: \.self) { issue in
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.callout)
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
                }
                .padding(16)
            }

            Divider()

            HStack(spacing: 8) {
                if detected {
                    Label("Detected", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Spacer()

                Button("Validate") {
                    let issues = paths.validate()
                    withAnimation { validationIssues = issues }
                    if issues.isEmpty {
                        withAnimation { saved = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { saved = false }
                        }
                    }
                }
                .controlSize(.small)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        paths = RuntimePaths.detectDefaults()
                        detected = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { detected = false }
                    }
                } label: {
                    Label("Auto-Detect", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Save") {
                    store.settings.runtimePaths = paths
                    store.saveSettings()
                    withAnimation {
                        validationIssues = []
                        saved = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { saved = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear {
            paths = store.settings.runtimePaths
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

    private func pathRow(_ label: String, path: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("", text: path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                    }
                }
                .controlSize(.small)
            }
        }
    }
}
