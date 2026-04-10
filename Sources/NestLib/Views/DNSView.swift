import SwiftUI

public struct DNSView: View {
    @EnvironmentObject private var store: SiteStore

    @State private var records: [CloudflareDNSRecord] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showAddSheet = false
    @State private var newSubdomain = ""
    @State private var recordPendingDeletion: CloudflareDNSRecord?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !store.settings.cloudflareSettings.hasAPIConfiguration {
                missingConfiguration
            } else if isLoading && records.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if records.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(records) { record in
                        DNSRouteRow(
                            record: record,
                            onDelete: { recordPendingDeletion = record }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            DNSAddRecordSheet(
                subdomain: $newSubdomain,
                onCancel: {
                    showAddSheet = false
                    newSubdomain = ""
                },
                onSave: {
                    createRecord()
                }
            )
        }
        .alert("DNS Status", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            "Delete DNS Route?",
            isPresented: .init(
                get: { recordPendingDeletion != nil },
                set: { if !$0 { recordPendingDeletion = nil } }
            ),
            actions: {
                Button("Delete", role: .destructive) {
                    if let recordPendingDeletion {
                        delete(recordPendingDeletion)
                    }
                    recordPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    recordPendingDeletion = nil
                }
            },
            message: {
                if let recordPendingDeletion {
                    Text("This will remove `\(recordPendingDeletion.name)` from Cloudflare.")
                }
            }
        )
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DNS Routes")
                    .font(.title2)
                    .fontWeight(.semibold)

                if store.settings.cloudflareSettings.hasAPIConfiguration {
                    Text("\(records.count) route\(records.count == 1 ? "" : "s") pointing at the current tunnel")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!store.settings.cloudflareSettings.hasAPIConfiguration || isLoading)

            Button {
                showAddSheet = true
            } label: {
                Label("Add Route", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!store.settings.cloudflareSettings.hasAPIConfiguration || isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var missingConfiguration: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "icloud.slash")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.quaternary)
            Text("Cloudflare API settings are incomplete.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open Settings > Cloudflare and fill in the API token, zone ID, account ID, tunnel ID, and tunnel domain.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.quaternary)
            Text("No DNS routes found for this tunnel.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Add DNS Route") {
                showAddSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Spacer()
        }
    }

    private func reload() {
        guard store.settings.cloudflareSettings.hasAPIConfiguration else { return }
        isLoading = true
        Task {
            do {
                let loaded = try await CloudflareService.listDNSRecords(settings: store.settings.cloudflareSettings)
                await MainActor.run {
                    records = loaded
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func createRecord() {
        let subdomain = newSubdomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subdomain.isEmpty else { return }

        isLoading = true
        Task {
            do {
                try await CloudflareService.createDNSRecord(
                    subdomain: subdomain,
                    settings: store.settings.cloudflareSettings
                )
                await MainActor.run {
                    showAddSheet = false
                    newSubdomain = ""
                }
                reload()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func delete(_ record: CloudflareDNSRecord) {
        isLoading = true
        Task {
            do {
                try await CloudflareService.deleteDNSRecord(
                    id: record.id,
                    settings: store.settings.cloudflareSettings
                )
                reload()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

private struct DNSRouteRow: View {
    let record: CloudflareDNSRecord
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(record.type)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(record.content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            if record.proxied {
                Text("Proxied")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                    )
                    .foregroundStyle(.orange)
            }

            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Delete Route", role: .destructive) {
                onDelete()
            }
        }
    }
}

private struct DNSAddRecordSheet: View {
    @Binding var subdomain: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New DNS Route")
                        .font(.headline)
                    Text("Creates a proxied CNAME pointing at the current Cloudflare tunnel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Subdomain")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                TextField("mysite", text: $subdomain)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
            }
            .padding(20)

            Divider()

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Route") { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(subdomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 420)
        .onAppear {
            isFocused = true
        }
    }
}
