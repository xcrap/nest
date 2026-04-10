import SwiftUI

public struct LogsView: View {
    @EnvironmentObject var store: SiteStore
    @State private var selectedLog: LogFile = .frankenphp
    @State private var content: String = ""
    @State private var isLoading = false
    @State private var autoRefresh = false
    @State private var loadTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?

    enum LogFile: String, CaseIterable, Identifiable {
        case frankenphp = "FrankenPHP"
        case cloudflared = "Cloudflared"
        case mariadb = "MariaDB"

        var id: String { rawValue }
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(spacing: 0) {
                logToolbar
                Divider()
                logContent
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: logReloadKey) {
            reloadLog()
        }
        .onDisappear {
            stopRefreshLoop()
            cancelLoad()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Logs")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Tail service logs without leaving the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var logToolbar: some View {
        HStack(spacing: 12) {
            Picker("Log", selection: $selectedLog) {
                ForEach(LogFile.allCases) { file in
                    Text(file.rawValue).tag(file)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Spacer()

            if currentLogPath.isEmpty {
                Label("No log path configured", systemImage: "exclamationmark.triangle")
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
            .onChange(of: autoRefresh) {
                if autoRefresh {
                    startRefreshLoop()
                } else {
                    stopRefreshLoop()
                }
            }

            Button {
                reloadLog()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh")

            Button {
                content = ""
                if !currentLogPath.isEmpty {
                    try? "".write(toFile: currentLogPath, atomically: true, encoding: .utf8)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Clear Log")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var logContent: some View {
        Group {
            if currentLogPath.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text("Set the log file path in Runtime Paths.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if isLoading && content.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if content.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text("Log file is empty.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                LogTextView(text: content)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Logic

    private var logReloadKey: String {
        "\(selectedLog.rawValue)|\(currentLogPath)"
    }

    private var currentLogPath: String {
        switch selectedLog {
        case .frankenphp: return store.settings.runtimePaths.frankenphpLog
        case .cloudflared: return store.settings.runtimePaths.cloudflaredLog
        case .mariadb: return store.settings.runtimePaths.mariadbLog
        }
    }

    private func reloadLog() {
        cancelLoad()

        let path = currentLogPath
        guard !path.isEmpty else {
            isLoading = false
            content = ""
            return
        }

        isLoading = true
        loadTask = Task {
            let loaded = await LogTailReader.load(path: path)
            guard !Task.isCancelled else {
                return
            }

            if currentLogPath == path {
                isLoading = false
                if content != loaded {
                    content = loaded
                }
            }
        }
    }

    private func startRefreshLoop() {
        stopRefreshLoop()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    reloadLog()
                }
            }
        }
    }

    private func stopRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }
}
