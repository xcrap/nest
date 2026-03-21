import SwiftUI

public enum SiteFormMode: Identifiable {
    case add
    case edit(Site)

    public var id: String {
        switch self {
        case .add: return "add"
        case .edit(let site): return site.id
        }
    }
}

public struct SiteFormSheet: View {
    @EnvironmentObject var store: SiteStore
    @Environment(\.dismiss) var dismiss

    public let mode: SiteFormMode

    @State private var name = ""
    @State private var domain = ""
    @State private var rootPath = ""
    @State private var documentRoot = "public"
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    public init(mode: SiteFormMode) { self.mode = mode }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "Edit Site" : "New Site")
                        .font(.headline)
                    Text(isEditing ? "Update site configuration." : "Add a new local development site.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            // Form
            VStack(spacing: 16) {
                field("Name", prompt: "My Project") {
                    TextField("", text: $name, prompt: Text("My Project"))
                        .textFieldStyle(.roundedBorder)
                }

                field("Domain", prompt: "mysite.test") {
                    HStack(spacing: 0) {
                        TextField("", text: $domain, prompt: Text("mysite"))
                            .textFieldStyle(.roundedBorder)
                        Text(".test")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                    }
                }

                field("Root Path", prompt: "/Users/...") {
                    HStack(spacing: 8) {
                        TextField("", text: $rootPath, prompt: Text("/path/to/project"))
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") { pickDirectory() }
                            .controlSize(.small)
                    }
                }

                field("Document Root", prompt: "") {
                    Picker("", selection: $documentRoot) {
                        Text("public/").tag("public")
                        Text(". (project root)").tag(".")
                        Text("web/").tag("web")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                        Spacer()
                    }
                }
            }
            .padding(20)

            Divider()

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "Save Changes" : "Add Site") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || domain.isEmpty || rootPath.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 480)
        .onAppear {
            if case .edit(let site) = mode {
                name = site.name
                domain = site.domain.replacingOccurrences(of: ".test", with: "")
                rootPath = site.rootPath
                documentRoot = site.documentRoot
            }
        }
    }

    private func field(_ label: String, prompt: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        let d = domain.hasSuffix(".test") ? domain : "\(domain).test"

        if case .add = mode {
            if store.site(forDomain: d) != nil {
                errorMessage = "A site with domain '\(d)' already exists."
                return
            }
        }

        switch mode {
        case .add:
            let _ = store.addSite(name: name, domain: d, rootPath: rootPath, documentRoot: documentRoot)
        case .edit(var site):
            site.name = name
            site.domain = d
            site.rootPath = rootPath
            site.documentRoot = documentRoot
            store.updateSite(site)
        }
        dismiss()
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = url.path
        }
    }
}
