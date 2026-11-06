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
    /// A project folder to start from (dropped on the Sites list).
    private let initialFolder: URL?

    @State private var name = ""
    @State private var domain = ""
    @State private var rootPath = ""
    @State private var documentRoot = "public"
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    public init(mode: SiteFormMode, folder: URL? = nil) {
        self.mode = mode
        self.initialFolder = folder
    }

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
                    TextField("Name", text: $name, prompt: Text("My Project"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }

                field("Domain", prompt: "mysite.test") {
                    HStack(spacing: 0) {
                        TextField("Domain", text: $domain, prompt: Text("mysite"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityHint("The .test suffix is added automatically.")
                        Text(".test")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                            .accessibilityHidden(true)
                    }
                }

                field("Root Path", prompt: "/Users/...") {
                    HStack(spacing: 8) {
                        TextField("Root path", text: $rootPath, prompt: Text("/path/to/project"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") { pickDirectory() }
                            .controlSize(.small)
                            .accessibilityLabel("Browse for the site folder")
                    }
                }

                field("Document Root", prompt: "") {
                    Picker("Document root", selection: $documentRoot) {
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
                domain = NestValidation.siteDomainLabel(site.domain)
                rootPath = site.rootPath
                documentRoot = site.documentRoot
            } else if let initialFolder {
                applyFolder(initialFolder)
            }
        }
    }

    private func field(_ label: String, prompt: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            content()
        }
    }

    /// Fills the root path and, for fields the user has not typed yet, a name and `.test`
    /// domain from the folder name and the document root from the folder's layout.
    private func applyFolder(_ url: URL) {
        rootPath = url.path
        let folderName = url.lastPathComponent
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = folderName
        }
        if domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            domain = Self.domainLabel(fromFolderName: folderName)
        }
        if !isEditing {
            var isDirectory: ObjCBool = false
            let hasPublic = FileManager.default.fileExists(atPath: url.appendingPathComponent("public").path, isDirectory: &isDirectory)
                && isDirectory.boolValue
            documentRoot = hasPublic ? "public" : "."
        }
    }

    /// "My Project_v2" → "my-project-v2": lowercase DNS label characters, runs of anything
    /// else collapsed to a single hyphen.
    static func domainLabel(fromFolderName folderName: String) -> String {
        let slug = folderName.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return NestValidation.siteDomainLabel(NestValidation.normalizedDomain(slug, defaultTLD: "test"))
    }

    private func save() {
        errorMessage = nil
        let normalizedDomain = NestValidation.normalizedDomain(domain, defaultTLD: "test")
        let candidate = Site(
            name: name,
            domain: normalizedDomain,
            rootPath: rootPath,
            documentRoot: documentRoot
        )

        let issues = NestValidation.siteIssues(candidate)
        guard issues.isEmpty else {
            errorMessage = issues.joined(separator: " ")
            return
        }

        let duplicate = store.sites.contains {
            $0.domain == normalizedDomain && $0.id != mode.id
        }
        if duplicate {
            errorMessage = "A site with domain '\(normalizedDomain)' already exists."
            return
        }

        switch mode {
        case .add:
            let _ = store.addSite(name: name, domain: normalizedDomain, rootPath: rootPath, documentRoot: documentRoot)
        case .edit(var site):
            site.name = name
            site.domain = normalizedDomain
            site.rootPath = rootPath
            site.documentRoot = documentRoot
            store.updateSite(site)
        }
        if let error = store.saveError(.sites) { errorMessage = error; return }
        dismiss()
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            applyFolder(url)
        }
    }
}
