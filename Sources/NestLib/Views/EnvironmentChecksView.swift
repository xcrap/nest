import SwiftUI

public struct EnvironmentChecksView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController
    @State private var checks: [PrerequisiteChecker.CheckResult] = []
    @State private var runtimeIssues: [String] = []

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Environment")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Recheck") {
                        runChecks()
                    }
                }

                // Runtime paths validation
                GroupBox("Runtime Binaries") {
                    if runtimeIssues.isEmpty {
                        Label("All runtime paths are valid.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(runtimeIssues, id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.callout)
                            }
                        }
                    }
                }

                // Services status
                GroupBox("Services") {
                    VStack(alignment: .leading, spacing: 8) {
                        serviceRow("FrankenPHP", running: processController.frankenphpRunning, error: processController.frankenphpError)
                        serviceRow("MariaDB", running: processController.mariadbRunning, error: processController.mariadbError)
                    }
                }

                // System prerequisites
                GroupBox("System Prerequisites (.test / HTTPS)") {
                    if checks.isEmpty {
                        Text("Click Recheck to verify prerequisites.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(checks) { check in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(check.passed ? .green : .red)
                                        Text(check.name)
                                            .fontWeight(.medium)
                                    }
                                    Text(check.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    if !check.passed && !check.fixHint.isEmpty {
                                        Text(check.fixHint)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .padding(6)
                                            .background(Color(nsColor: .textBackgroundColor))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                            }
                        }
                    }
                }

                // MariaDB controls
                GroupBox("MariaDB") {
                    HStack {
                        Circle()
                            .fill(processController.mariadbRunning ? .green : .secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                        Text(processController.mariadbRunning ? "Running" : "Stopped")
                        Spacer()
                        if processController.mariadbRunning {
                            Button("Stop") {
                                processController.stopMariaDB()
                            }
                        } else {
                            Button("Start") {
                                let paths = store.settings.runtimePaths
                                processController.startMariaDB(
                                    serverBinary: paths.mariadbServer,
                                    dataDirectory: store.settings.dataDirectory + "/mariadb",
                                    configDirectory: store.settings.configDirectory
                                )
                            }
                            .disabled(store.settings.runtimePaths.mariadbServer.isEmpty)
                        }
                    }
                    if let error = processController.mariadbError {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .padding()
        }
        .onAppear {
            runChecks()
        }
    }

    private func runChecks() {
        checks = PrerequisiteChecker.checkAll()
        runtimeIssues = store.settings.runtimePaths.validate()
    }

    private func serviceRow(_ name: String, running: Bool, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle()
                    .fill(running ? .green : .secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(name)
                Text(running ? "Running" : "Stopped")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }
}
