import SwiftUI

public enum ProjectFormMode: Identifiable {
    case add
    case edit(AppProject)

    public var id: String {
        switch self {
        case .add: return "add"
        case .edit(let project): return project.id
        }
    }
}

public struct ProjectFormSheet: View {
    @EnvironmentObject var store: SiteStore
    @Environment(\.dismiss) private var dismiss

    public let mode: ProjectFormMode

    @State private var name = ""
    @State private var hostname = ""
    @State private var directory = ""
    @State private var port = ""
    @State private var command = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case hostname
        case directory
        case port
        case command
    }

    public init(mode: ProjectFormMode) {
        self.mode = mode
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 520)
        .onAppear {
            if case .edit(let project) = mode {
                name = project.name
                hostname = project.hostname
                directory = project.directory
                port = "\(project.port)"
                command = project.command
            }
            focusedField = .name
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Project" : "New Project")
                    .font(.headline)
                Text("Projects run as external user services and keep running after Nest quits.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var form: some View {
        VStack(spacing: 16) {
            field("Name") {
                TextField("Azores Webcams", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
            }

            field("Hostname") {
                TextField("azo.waka.pt", text: $hostname)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .hostname)
            }

            field("Directory") {
                HStack(spacing: 8) {
                    TextField("/Users/xcrap/projects/app", text: $directory)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .directory)
                    Button("Browse...") { pickDirectory() }
                        .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                field("Port") {
                    TextField("3999", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .port)
                }

                field("Command") {
                    TextField("Leave blank to auto-detect", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .command)
                }
            }

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                    Spacer()
                }
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(isEditing ? "Save Changes" : "Add Project") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || Int(port) == nil)
        }
        .padding(20)
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        guard let parsedPort = Int(port), parsedPort > 0 else {
            errorMessage = "Port must be a valid number."
            return
        }

        let duplicateHostname = store.appProjects.contains {
            $0.hostname == hostname && (mode.id != $0.id)
        }
        if duplicateHostname {
            errorMessage = "A project with hostname '\(hostname)' already exists."
            return
        }

        switch mode {
        case .add:
            _ = store.addProject(
                name: name,
                hostname: hostname,
                directory: directory,
                port: parsedPort,
                command: command
            )
        case .edit(var project):
            project.name = name
            project.hostname = hostname
            project.directory = directory
            project.port = parsedPort
            project.command = command
            store.updateProject(project)
        }

        dismiss()
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
        }
    }
}
