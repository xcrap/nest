import SwiftUI

public struct ProjectsView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController

    @State private var showAddSheet = false
    @State private var editingProject: AppProject?
    @State private var logProject: AppProject?
    @State private var searchText = ""
    @State private var hoveredProjectId: String?

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

            if store.appProjects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredProjects) { project in
                            ProjectRow(
                                project: project,
                                isRunning: processController.isProjectRunning(project),
                                operation: processController.projectOperation(for: project.id),
                                isHovered: hoveredProjectId == project.id,
                                error: processController.projectError(for: project.id),
                                onEdit: { editingProject = project },
                                onShowLog: { logProject = project }
                            )
                            .onHover { h in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    hoveredProjectId = h ? project.id : nil
                                }
                            }
                            if project.id != filteredProjects.last?.id {
                                Divider().padding(.leading, 36)
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
                TextField("Filter...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

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
            .help("Refresh")

            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("n", modifiers: .command)
            .help("Add Project (Cmd+N)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.quaternary)
                Text("No projects yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Add Project") { showAddSheet = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Spacer()
        }
    }

    private func refreshStatuses() {
        processController.refreshProjectStatuses(store.appProjects)
    }
}

// MARK: - Project Row

private struct ProjectRow: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController

    let project: AppProject
    let isRunning: Bool
    let operation: ProcessController.ProjectOperation?
    let isHovered: Bool
    let error: String?
    let onEdit: () -> Void
    let onShowLog: () -> Void

    @State private var hoveredAction: String?

    private var isBusy: Bool {
        operation != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 8, height: 8)

                Text(project.name)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)

                Text(project.hostname)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)

                Text(project.directory)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(":\(project.port)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 50, alignment: .trailing)

                HStack(spacing: 0) {
                    rowAction(icon: "doc.text", help: "Logs") { onShowLog() }
                    rowAction(icon: "pencil", help: "Edit") { onEdit() }
                    rowAction(icon: "trash", help: "Delete") {
                        processController.stopProject(project)
                        store.deleteProject(id: project.id)
                    }
                }
                .opacity(isHovered ? 1 : 0)
                .disabled(isBusy)

                StartStopButton(isRunning: isRunning, isPending: isBusy) {
                    if isRunning {
                        processController.stopProject(project)
                    } else {
                        processController.startProject(project)
                    }
                }
            }

            if let error, !error.isEmpty {
                HStack {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit...") { onEdit() }
                .disabled(isBusy)
            Button("View Logs") { onShowLog() }
                .disabled(isBusy)
            Button(isRunning ? "Stop" : "Start") {
                if isRunning {
                    processController.stopProject(project)
                } else {
                    processController.startProject(project)
                }
            }
            .disabled(isBusy)
            Divider()
            Button("Delete", role: .destructive) {
                processController.stopProject(project)
                store.deleteProject(id: project.id)
            }
            .disabled(isBusy)
        }
    }

    private func rowAction(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.callout)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(hoveredAction == icon ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hoveredAction == icon ? .primary : .secondary)
        .onHover { h in hoveredAction = h ? icon : nil }
        .help(help)
    }
}

// MARK: - Project Log Sheet

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
            guard !Task.isCancelled else { return }
            isLoading = false
            if content != loaded { content = loaded }
        }
    }

    private func startRefreshLoop() {
        stopRefreshLoop()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { load() }
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
