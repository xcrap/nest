import SwiftUI

public struct ProjectsView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var processController: ProcessController

    @State private var showAddSheet = false
    @State private var editingProject: AppProject?
    @State private var logProject: AppProject?
    @State private var searchText = ""
    @State private var pendingDeletion: AppProject?
    @State private var deletionError: String?

    public init() {}

    private var filteredProjects: [AppProject] {
        let sorted = store.appProjects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if searchText.isEmpty { return sorted }
        let query = searchText.lowercased()
        return sorted.filter {
            $0.name.lowercased().contains(query)
            || $0.hostname.lowercased().contains(query)
            || ($0.localDomain?.contains(query) ?? false)
            || $0.directory.lowercased().contains(query)
        }
    }

    public var body: some View {
        let projects = filteredProjects
        let lastID = projects.last?.id
        VStack(spacing: 0) {
            toolbar(projects: projects)
            Divider()

            if store.appProjects.isEmpty {
                emptyState
            } else if projects.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(projects) { project in
                            // Rows get plain values and are Equatable, so a status change
                            // re-renders only the rows whose values changed.
                            ProjectRow(
                                project: project,
                                isRunning: processController.isProjectRunning(project),
                                operation: processController.projectOperation(for: project.id),
                                error: processController.projectError(for: project.id),
                                onToggleRunning: { toggleRunning(project) },
                                onEdit: { editingProject = project },
                                onShowLog: { logProject = project },
                                onDelete: { pendingDeletion = project }
                            )
                            .equatable()
                            if project.id != lastID {
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
        .alert("Delete Project?", isPresented: .init(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Delete", role: .destructive) {
                if let project = pendingDeletion { delete(project) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Stop \(pendingDeletion?.name ?? "this project") and remove it from Nest? Its files stay on disk.")
        }
        .alert("Could Not Delete Project", isPresented: .init(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK") { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
        .onAppear(perform: refreshStatuses)
    }

    /// Reads the live status at click time, not the value the row was rendered with.
    private func toggleRunning(_ project: AppProject) {
        if processController.isProjectRunning(project) {
            processController.stopProject(project)
        } else {
            processController.startProject(project)
        }
    }

    /// The record is removed only once its launch agent is gone; otherwise it would keep
    /// starting at login with no row left to stop it.
    private func delete(_ project: AppProject) {
        Task {
            if let error = await processController.stopProjectForDeletion(project) {
                deletionError = error
            } else {
                store.deleteProject(id: project.id)
            }
        }
    }

    private func toolbar(projects: [AppProject]) -> some View {
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
                        Label("Clear Filter", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
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

            Text("\(projects.filter(processController.isProjectRunning).count)/\(projects.count) running")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                refreshStatuses()
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh")

            Button {
                showAddSheet = true
            } label: {
                Label("Add Project", systemImage: "plus")
                    .labelStyle(.iconOnly)
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

private struct ProjectRow: View, Equatable {
    let project: AppProject
    let isRunning: Bool
    let operation: ProcessController.ProjectOperation?
    let error: String?
    let onToggleRunning: () -> Void
    let onEdit: () -> Void
    let onShowLog: () -> Void
    let onDelete: () -> Void

    @Environment(\.openURL) private var openURL

    /// Row-local so hovering redraws one row, not the whole list.
    @State private var isHovered = false
    @State private var hoveredAction: String?
    /// Keyboard focus on a row action keeps the actions visible without hovering.
    @FocusState private var focusedAction: String?

    /// The closures only capture `project`, so comparing the values is enough.
    static func == (lhs: ProjectRow, rhs: ProjectRow) -> Bool {
        lhs.project == rhs.project && lhs.isRunning == rhs.isRunning
            && lhs.operation == rhs.operation && lhs.error == rhs.error
    }

    private var isBusy: Bool {
        operation != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(project.name)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text(project.hostname)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let localDomain = project.localDomain {
                        Text(localDomain)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .accessibilityLabel("Local domain \(localDomain)")
                    }
                }
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
                    .accessibilityLabel("Port \(project.port)")

                HStack(spacing: 0) {
                    // Opening the page stays possible while the project starts or stops.
                    if let localURL = project.localURL {
                        rowAction(icon: "globe", title: "Open in Browser", help: "Open \(localURL.absoluteString)") { openURL(localURL) }
                    } else {
                        // Keeps the columns aligned with rows that have the button.
                        Color.clear.frame(width: 26, height: 26).accessibilityHidden(true)
                    }
                    Group {
                        rowAction(icon: "doc.text", title: "View Logs") { onShowLog() }
                        rowAction(icon: "pencil", title: "Edit") { onEdit() }
                        rowAction(icon: "trash", title: "Delete") { onDelete() }
                    }
                    .disabled(isBusy)
                }
                .opacity(isHovered || focusedAction != nil ? 1 : 0)

                StartStopButton(isRunning: isRunning, isPending: isBusy, action: onToggleRunning)
                    .accessibilityLabel("\(isRunning ? "Stop" : "Start") \(project.name)")
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .contextMenu {
            if let localURL = project.localURL {
                Button("Open \(localURL.absoluteString)") { openURL(localURL) }
                Divider()
            }
            Button("Edit...") { onEdit() }
                .disabled(isBusy)
            Button("View Logs") { onShowLog() }
                .disabled(isBusy)
            Button(isRunning ? "Stop" : "Start") { onToggleRunning() }
                .disabled(isBusy)
            Divider()
            Button("Delete…", role: .destructive) { onDelete() }
                .disabled(isBusy)
        }
        // The hover-only buttons are invisible to VoiceOver; offer the same actions on the row.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(project.name)
        .accessibilityValue(isBusy ? (operation?.label ?? "") : (isRunning ? "Running" : "Stopped"))
        .accessibilityActions {
            if let localURL = project.localURL {
                Button("Open in Browser") { openURL(localURL) }
            }
        }
        .accessibilityAction(named: "View Logs") { if !isBusy { onShowLog() } }
        .accessibilityAction(named: "Edit") { if !isBusy { onEdit() } }
        .accessibilityAction(named: isRunning ? "Stop" : "Start") { if !isBusy { onToggleRunning() } }
        .accessibilityAction(named: "Delete") { if !isBusy { onDelete() } }
    }

    private func rowAction(icon: String, title: String, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
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
        .focused($focusedAction, equals: icon)
        .help(help ?? title)
        .accessibilityLabel("\(title) \(project.name)")
    }
}

// MARK: - Project Log Sheet

private struct ProjectLogSheet: View {
    let project: AppProject
    @Environment(\.dismiss) private var dismiss
    @StateObject private var log = LogTailModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.headline)
                    Text(project.logPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ZStack {
                LogTextView(model: log)
                    .opacity(log.status == .content ? 1 : 0)
                    .accessibilityHidden(log.status != .content)
                LogStatusPlaceholder(
                    status: log.status,
                    path: project.logPath,
                    emptyTitle: "No log output yet",
                    missingTitle: "No log output yet",
                    missingDetail: "The log file is created when the project first runs."
                )
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .task(id: project.logPath) {
            log.follow(path: project.logPath)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                log.refresh()
            }
        }
    }
}
