import SwiftUI

public struct EnvironmentChecksView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController
    @State private var checks: [PrerequisiteChecker.CheckResult] = []
    @State private var runtimeIssues: [String] = []

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Environment")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("System prerequisites and service health.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        runChecks()
                    }
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(spacing: 16) {

                    // Services
                    sectionCard(title: "Services", icon: "play.circle.fill", color: .green) {
                        VStack(spacing: 0) {
                            serviceControl(
                                name: "FrankenPHP",
                                icon: "bolt.fill",
                                running: processController.frankenphpRunning,
                                error: processController.frankenphpError,
                                onStart: { startFrankenPHP() },
                                onStop: { processController.stopFrankenPHP() }
                            )
                            Divider().padding(.horizontal, 4)
                            serviceControl(
                                name: "MariaDB",
                                icon: "cylinder.fill",
                                running: processController.mariadbRunning,
                                error: processController.mariadbError,
                                onStart: { startMariaDB() },
                                onStop: { processController.stopMariaDB() }
                            )
                        }
                    }

                    // Runtime binaries
                    sectionCard(title: "Runtime Binaries", icon: "wrench.and.screwdriver.fill", color: .purple) {
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
                                            .font(.caption)
                                        Text(issue)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    // System prerequisites
                    sectionCard(title: "System Prerequisites", icon: "shield.checkered", color: .blue) {
                        VStack(spacing: 0) {
                            ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                                if index > 0 {
                                    Divider().padding(.horizontal, 4)
                                }
                                prerequisiteRow(check)
                            }
                        }
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .onAppear { runChecks() }
    }

    // MARK: - Components

    private func sectionCard(title: String, icon: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
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

    private func serviceControl(
        name: String,
        icon: String,
        running: Bool,
        error: String?,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(running ? .green : .secondary)
                    .frame(width: 16)

                Text(name)
                    .font(.callout)
                    .fontWeight(.medium)

                HStack(spacing: 5) {
                    Circle()
                        .fill(running ? Color.green : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                    Text(running ? "Running" : "Stopped")
                        .font(.caption)
                        .foregroundStyle(running ? .green : .secondary)
                }

                Spacer()

                Button(running ? "Stop" : "Start") {
                    if running { onStop() } else { onStart() }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(running ? .red : .green)
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
                Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(check.passed ? .green : .red)
                    .font(.callout)
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.name)
                        .font(.callout)
                        .fontWeight(.medium)
                    Text(check.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !check.passed && !check.fixHint.isEmpty {
                Text(check.fixHint)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func runChecks() {
        checks = PrerequisiteChecker.checkAll()
        runtimeIssues = store.settings.runtimePaths.validate()
    }

    private func startFrankenPHP() {
        let paths = store.settings.runtimePaths
        guard !paths.frankenphpBinary.isEmpty else { return }
        let renderer = ConfigRenderer(
            configDirectory: store.settings.configDirectory,
            logDirectory: paths.logDirectory
        )
        try? renderer.writeAll(sites: store.sites)
        processController.startFrankenPHP(binary: paths.frankenphpBinary, caddyfilePath: renderer.caddyfilePath)
    }

    private func startMariaDB() {
        let paths = store.settings.runtimePaths
        guard !paths.mariadbServer.isEmpty else { return }
        processController.startMariaDB(
            serverBinary: paths.mariadbServer,
            dataDirectory: store.settings.dataDirectory + "/mariadb",
            configDirectory: store.settings.configDirectory
        )
    }
}
