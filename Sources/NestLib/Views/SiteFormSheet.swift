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

    private var title: String {
        isEditing ? "Edit Site" : "Add Site"
    }

    public init(mode: SiteFormMode) {
        self.mode = mode
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding()

            Form {
                TextField("Name", text: $name)
                TextField("Domain", text: $domain, prompt: Text("mysite.test"))
                HStack {
                    TextField("Root Path", text: $rootPath)
                    Button("Browse…") {
                        pickDirectory()
                    }
                }
                Picker("Document Root", selection: $documentRoot) {
                    Text("public").tag("public")
                    Text(". (project root)").tag(".")
                    Text("web").tag("web")
                }
            }
            .formStyle(.grouped)

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "Save" : "Add") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || domain.isEmpty || rootPath.isEmpty)
            }
            .padding()
        }
        .frame(width: 450)
        .onAppear {
            if case .edit(let site) = mode {
                name = site.name
                domain = site.domain
                rootPath = site.rootPath
                documentRoot = site.documentRoot
            }
        }
    }

    private func save() {
        let d = domain.hasSuffix(".test") ? domain : "\(domain).test"

        // Check for duplicate domain
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
