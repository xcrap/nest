import SwiftUI

public struct RuntimePathsView: View {
    @EnvironmentObject var store: SiteStore
    @State private var paths: RuntimePaths = RuntimePaths()
    @State private var validationIssues: [String] = []
    @State private var saved = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Runtime Paths")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Detect Defaults") {
                    paths = RuntimePaths.detectDefaults()
                }
            }
            .padding()

            Divider()

            Form {
                Section("FrankenPHP") {
                    PathField(label: "Binary", path: $paths.frankenphpBinary)
                }

                Section("MariaDB") {
                    PathField(label: "Server (mariadbd)", path: $paths.mariadbServer)
                    PathField(label: "Client (mariadb)", path: $paths.mariadbClient)
                    PathField(label: "mysqldump", path: $paths.mysqldump)
                }

                Section("Logs") {
                    PathField(label: "Log Directory", path: $paths.logDirectory, isDirectory: true)
                }

                if !validationIssues.isEmpty {
                    Section("Issues") {
                        ForEach(validationIssues, id: \.self) { issue in
                            Label(issue, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                if saved {
                    Text("Saved")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Button("Validate") {
                    validationIssues = paths.validate()
                }
                Button("Save") {
                    store.settings.runtimePaths = paths
                    store.saveSettings()
                    validationIssues = []
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .onAppear {
            paths = store.settings.runtimePaths
        }
    }
}

public struct PathField: View {
    public let label: String
    @Binding public var path: String
    public var isDirectory: Bool = false

    public init(label: String, path: Binding<String>, isDirectory: Bool = false) {
        self.label = label
        self._path = path
        self.isDirectory = isDirectory
    }

    public var body: some View {
        HStack {
            TextField(label, text: $path)
                .textFieldStyle(.roundedBorder)
            Button("Browse…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = isDirectory
                panel.canChooseFiles = !isDirectory
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    path = url.path
                }
            }
        }
    }
}
