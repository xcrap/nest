import SwiftUI

public struct LogsView: View {
    @EnvironmentObject var store: SiteStore
    @State private var selectedLog: LogFile = .frankenphp
    @State private var content: String = ""
    @State private var autoRefresh = false
    @State private var refreshTimer: Timer?

    enum LogFile: String, CaseIterable, Identifiable {
        case frankenphp = "FrankenPHP"
        case mariadb = "MariaDB"

        var id: String { rawValue }
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            logToolbar
            Divider()
            logContent
        }
        .onAppear { loadLog() }
        .onChange(of: selectedLog) { loadLog() }
        .onDisappear { stopTimer() }
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
                if autoRefresh { startTimer() } else { stopTimer() }
            }

            Button {
                loadLog()
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
                ScrollView([.horizontal, .vertical]) {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    // MARK: - Logic

    private var currentLogPath: String {
        switch selectedLog {
        case .frankenphp: return store.settings.runtimePaths.frankenphpLog
        case .mariadb: return store.settings.runtimePaths.mariadbLog
        }
    }

    private func loadLog() {
        let path = currentLogPath
        guard !path.isEmpty else {
            content = ""
            return
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            content = ""
            return
        }
        // Show last 500KB max
        let maxBytes = 500_000
        let slice = data.count > maxBytes ? data.suffix(maxBytes) : data
        content = String(data: slice, encoding: .utf8) ?? ""
    }

    private func startTimer() {
        stopTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            loadLog()
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
