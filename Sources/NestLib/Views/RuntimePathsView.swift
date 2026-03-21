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
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Runtime Paths")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Configure the paths to your locally installed binaries and log files.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if detected {
                    Label("Detected", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
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
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // FrankenPHP
                    settingsCard(title: "FrankenPHP", icon: "bolt.fill", color: .purple) {
                        VStack(spacing: 12) {
                            pathRow("Binary", path: $paths.frankenphpBinary, isDirectory: false)
                            pathRow("Log File", path: $paths.frankenphpLog, isDirectory: false)
                        }
                    }

                    // MariaDB
                    settingsCard(title: "MariaDB", icon: "cylinder.fill", color: .blue) {
                        VStack(spacing: 12) {
                            pathRow("Server (mariadbd)", path: $paths.mariadbServer, isDirectory: false)
                            pathRow("Client (mariadb)", path: $paths.mariadbClient, isDirectory: false)
                            pathRow("mysqldump", path: $paths.mysqldump, isDirectory: false)
                            pathRow("Log File", path: $paths.mariadbLog, isDirectory: false)
                        }
                    }

                    // Validation issues
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
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.orange.opacity(0.06))
                                .strokeBorder(Color.orange.opacity(0.15), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 16)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                Button("Validate") {
                    let issues = paths.validate()
                    withAnimation {
                        validationIssues = issues
                    }
                    if issues.isEmpty {
                        withAnimation { saved = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { saved = false }
                        }
                    }
                }
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
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .onAppear {
            paths = store.settings.runtimePaths
        }
    }

    private func settingsCard(title: String, icon: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(color)
                    .frame(width: 20, height: 20)
                    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 20)
    }

    private func pathRow(_ label: String, path: Binding<String>, isDirectory: Bool) -> some View {
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
                    panel.canChooseDirectories = isDirectory
                    panel.canChooseFiles = !isDirectory
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
