import SwiftUI

public struct LogsView: View {
    @EnvironmentObject var store: SiteStore
    @State private var selectedLog: LogFile = .frankenphp
    @StateObject private var log = LogTailModel()
    @State private var autoRefresh = false
    @State private var confirmClear = false
    @State private var clearError: String?

    enum LogFile: String, CaseIterable, Identifiable {
        case frankenphp = "FrankenPHP"
        case cloudflared = "Cloudflared"
        case mariadb = "MariaDB"

        var id: String { rawValue }
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: currentLogPath) {
            log.follow(path: currentLogPath)
        }
        .task(id: autoRefresh) {
            guard autoRefresh else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                log.refresh()
            }
        }
        .alert("Clear \(selectedLog.rawValue) Log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { clearLog() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently empties \(currentLogPath).")
        }
        .alert("Could Not Clear Log", isPresented: .init(get: { clearError != nil }, set: { if !$0 { clearError = nil } })) {
            Button("OK") { clearError = nil }
        } message: {
            Text(clearError ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Log", selection: $selectedLog) {
                ForEach(LogFile.allCases) { file in
                    Text(file.rawValue).tag(file)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Spacer()

            if currentLogPath.isEmpty {
                Label("No path configured", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(currentLogPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Toggle(isOn: $autoRefresh) {
                Text("Auto")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Refresh every 2 seconds")
            .accessibilityLabel("Auto-refresh log")

            Button {
                log.refresh()
            } label: {
                Label("Refresh Log", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(currentLogPath.isEmpty)
            .help("Refresh")

            Button {
                confirmClear = true
            } label: {
                Label("Clear Log", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(currentLogPath.isEmpty)
            .help("Clear Log")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var logContent: some View {
        Group {
            if currentLogPath.isEmpty {
                LogPlaceholder(icon: "doc.text.magnifyingglass", title: "No log file configured",
                               detail: "Set the log file path in Settings > Paths.")
            } else {
                // The text view stays mounted so it keeps its scroll position and selection
                // while the status changes; placeholders cover it instead.
                ZStack {
                    LogTextView(model: log)
                        .opacity(log.status == .content ? 1 : 0)
                        .accessibilityHidden(log.status != .content)
                    LogStatusPlaceholder(status: log.status, path: currentLogPath)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Logic

    private var currentLogPath: String {
        switch selectedLog {
        case .frankenphp: return store.settings.runtimePaths.frankenphpLog
        case .cloudflared: return store.settings.runtimePaths.cloudflaredLog
        case .mariadb: return store.settings.runtimePaths.mariadbLog
        }
    }

    private func clearLog() {
        let path = currentLogPath
        guard !path.isEmpty else { return }
        do {
            try LogTailReader.truncate(path: path)
            log.reload()
        } catch {
            clearError = error.localizedDescription
        }
    }
}

/// What to show over the log text when there is no output to display.
struct LogStatusPlaceholder: View {
    let status: LogTailModel.Status
    let path: String
    var emptyTitle = "Log file is empty"
    var missingTitle = "Log file not found"
    var missingDetail: String?

    var body: some View {
        switch status {
        case .idle, .content:
            EmptyView()
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        case .missing:
            LogPlaceholder(
                icon: "questionmark.folder",
                title: missingTitle,
                detail: missingDetail ?? "Nothing exists at \(path) yet. The service creates it when it first writes; otherwise check the path in Settings > Paths."
            )
        case .unreadable(let message):
            LogPlaceholder(icon: "exclamationmark.triangle", title: "Can’t read the log file", detail: message, warning: true)
        case .empty:
            LogPlaceholder(icon: "doc.text", title: emptyTitle, detail: nil)
        }
    }
}

/// Centered message shown instead of log output.
struct LogPlaceholder: View {
    let icon: String
    let title: String
    let detail: String?
    var warning = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.quaternary))
                .accessibilityHidden(true)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .combine)
    }
}
