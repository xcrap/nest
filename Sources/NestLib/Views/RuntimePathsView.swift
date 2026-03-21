import SwiftUI

public struct RuntimePathsView: View {
    @EnvironmentObject var store: SiteStore
    @State private var paths: RuntimePaths = RuntimePaths()
    @State private var validationIssues: [String] = []
    @State private var saved = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Runtime Paths")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Configure the paths to your locally installed binaries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        paths = RuntimePaths.detectDefaults()
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
                        pathRow("Binary", path: $paths.frankenphpBinary, isDirectory: false)
                    }

                    // MariaDB
                    settingsCard(title: "MariaDB", icon: "cylinder.fill", color: .blue) {
                        VStack(spacing: 10) {
                            pathRow("Server (mariadbd)", path: $paths.mariadbServer, isDirectory: false)
                            Divider().padding(.leading, 4)
                            pathRow("Client (mariadb)", path: $paths.mariadbClient, isDirectory: false)
                            Divider().padding(.leading, 4)
                            pathRow("mysqldump", path: $paths.mysqldump, isDirectory: false)
                        }
                    }

                    // Logs
                    settingsCard(title: "Logs", icon: "doc.text.fill", color: .orange) {
                        pathRow("Log Directory", path: $paths.logDirectory, isDirectory: true)
                    }

                    // Validation issues
                    if !validationIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(validationIssues, id: \.self) { issue in
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                    Text(issue)
                                        .font(.caption)
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
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                Button("Validate") {
                    validationIssues = paths.validate()
                }
                .controlSize(.small)
                Button("Save") {
                    store.settings.runtimePaths = paths
                    store.saveSettings()
                    validationIssues = []
                    withAnimation { saved = true }
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
                    .font(.caption)
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
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .padding(.horizontal, 20)
    }

    private func pathRow(_ label: String, path: Binding<String>, isDirectory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("", text: path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
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
