import SwiftUI

public struct ProjectsView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController

    @State private var showAddSheet = false
    @State private var editingProject: AppProject?
    @State private var logProject: AppProject?
    @State private var searchText = ""

    public init() {}

    private var filteredProjects: [AppProject] {
        let sorted = store.appProjects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if searchText.isEmpty { return sorted }
        let query = searchText.lowercased()
        return sorted.filter {
            $0.name.lowercased().contains(query)
            || $0.hostname.lowercased().contains(query)
            || $0.directory.lowercased().contains(query)
        }
    }

    private var runningCount: Int {
        filteredProjects.filter(processController.isProjectRunning).count
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if filteredProjects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredProjects) { project in
                            ProjectRow(
                                project: project,
                                isRunning: processController.isProjectRunning(project),
                                error: processController.projectError(for: project.id),
                                onEdit: { editingProject = project },
                                onShowLog: { logProject = project }
                            )
                            if project.id != filteredProjects.last?.id {
                                Divider().padding(.leading, 32)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ProjectFormSheet(mode: .add)
        }
        .sheet(item: $editingProject) { project in
            ProjectFormSheet(mode: .edit(project))
        }
        .sheet(item: $logProject) { project in
            ProjectLogSheet(project: project)
        }
        .onAppear(perform: refreshStatuses)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshStatuses()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            searchField

            Spacer()

            Text("\(runningCount)/\(filteredProjects.count) running")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                refreshStatuses()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh Status")

            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Filter projects...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.quaternary)
            Text("No projects yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Add Project") { showAddSheet = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Spacer()
        }
    }

    private func refreshStatuses() {
        processController.refreshProjectStatuses(store.appProjects)
    }
}

private struct ProjectRow: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController

    let project: AppProject
    let isRunning: Bool
    let error: String?
    let onEdit: () -> Void
    let onShowLog: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 8, height: 8)

                Text(project.name)
                    .font(.callout)
                    .fontWeight(.medium)
                    .frame(width: 150, alignment: .leading)

                Text(project.hostname)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 190, alignment: .leading)

                Text(project.directory)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(":\(project.port)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)

                Button("Log") { onShowLog() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Edit") { onEdit() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Delete", role: .destructive) {
                    processController.stopProject(project)
                    store.deleteProject(id: project.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(isRunning ? "Stop" : "Start") {
                    if isRunning {
                        processController.stopProject(project)
                    } else {
                        processController.startProject(project)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(isRunning ? .red : .green)
            }

            if let error, !error.isEmpty {
                HStack {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct ProjectLogSheet: View {
    let project: AppProject
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.headline)
                    Text(project.logPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            Group {
                if isLoading && content.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if content.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "doc.text")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.quaternary)
                        Text("No log output yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    LogTextView(text: content)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear {
            load()
            startRefreshLoop()
        }
        .onDisappear {
            stopRefreshLoop()
            cancelLoad()
        }
    }

    private func load() {
        cancelLoad()
        isLoading = true

        let logPath = project.logPath
        loadTask = Task {
            let loaded = await LogTailReader.load(path: logPath)
            guard !Task.isCancelled else {
                return
            }

            isLoading = false
            if content != loaded {
                content = loaded
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
                    load()
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
