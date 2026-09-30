import SwiftUI

public struct DNSView: View {
    @EnvironmentObject private var store: SiteStore

    @State private var records: [CloudflareDNSRecord] = []
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var showAddSheet = false
    @State private var newSubdomain = ""
    @State private var addError: String?
    @State private var recordPendingDeletion: CloudflareDNSRecord?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if !store.settings.cloudflareSettings.hasAPIConfiguration {
                missingConfiguration
            } else if isLoading && records.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError, records.isEmpty {
                ContentUnavailableView {
                    Label("Could not load DNS routes", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(loadError).textSelection(.enabled)
                } actions: {
                    Button("Retry") { reload() }
                }
            } else if records.isEmpty {
                emptyState
            } else {
                if let loadError {
                    // The list below is from the last successful load; say so instead of failing silently.
                    Label("Could not refresh: \(loadError)", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    Divider()
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(records) { record in
                            DNSRouteRow(
                                record: record,
                                onDelete: { recordPendingDeletion = record }
                            )
                            .disabled(isMutating)
                            if record.id != records.last?.id {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            DNSAddRecordSheet(
                subdomain: $newSubdomain,
                isSubmitting: isMutating,
                errorMessage: addError,
                onCancel: {
                    showAddSheet = false
                    newSubdomain = ""
                    addError = nil
                },
                onSave: { createRecord() }
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
                    Text("Remove \(recordPendingDeletion.name) from Cloudflare.")
                }
            }
        )
        .onAppear(perform: reload)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("\(records.count) route\(records.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!store.settings.cloudflareSettings.hasAPIConfiguration || isLoading)
            .help("Refresh")

            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!store.settings.cloudflareSettings.hasAPIConfiguration || isLoading || isMutating)
            .help("Add DNS Route")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var missingConfiguration: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.quaternary)
                Text("Cloudflare API not configured")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Fill in the API token, zone ID, account ID, tunnel ID and domain in Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "globe")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.quaternary)
                Text("No DNS routes found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Add DNS Route") { showAddSheet = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Spacer()
        }
    }

    private func reload() {
        guard store.settings.cloudflareSettings.hasAPIConfiguration, !isLoading else { return }
        isLoading = true
        Task {
            do {
                records = try await CloudflareService.listDNSRecords(settings: store.settings.cloudflareSettings)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// One request at a time; failures stay in the sheet, where the user is looking.
    private func createRecord() {
        let subdomain = newSubdomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subdomain.isEmpty, !isMutating else { return }

        isMutating = true
        addError = nil
        Task {
            defer { isMutating = false }
            do {
                try await CloudflareService.createDNSRecord(
                    subdomain: subdomain,
                    settings: store.settings.cloudflareSettings
                )
                showAddSheet = false
                newSubdomain = ""
                reload()
            } catch {
                addError = error.localizedDescription
            }
        }
    }

    private func delete(_ record: CloudflareDNSRecord) {
        guard !isMutating else { return }
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                try await CloudflareService.deleteDNSRecord(
                    id: record.id,
                    settings: store.settings.cloudflareSettings
                )
                records.removeAll { $0.id == record.id }
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - DNS Route Row

private struct DNSRouteRow: View {
    let record: CloudflareDNSRecord
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var hoveredAction: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(record.type)
                .font(.caption2)
                .fontWeight(.semibold)
                .frame(width: 42)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                )
                .foregroundStyle(.blue)

            Text(record.name)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.quaternary)

            Text(record.content)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if record.proxied {
                Text("Proxied")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                    )
                    .foregroundStyle(.orange)
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.callout)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(hoveredAction == "trash" ? Color.primary.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(hoveredAction == "trash" ? .primary : .secondary)
            .onHover { h in hoveredAction = h ? "trash" : nil }
            .opacity(isHovered ? 1 : 0)
            .help("Delete")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .contextMenu {
            Button("Delete Route", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Add Record Sheet

private struct DNSAddRecordSheet: View {
    @Binding var subdomain: String
    let isSubmitting: Bool
    let errorMessage: String?
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Subdomain")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                TextField("mysite", text: $subdomain)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .disabled(isSubmitting)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isSubmitting {
                    ProgressView().controlSize(.small)
                }
                Button("Add Route") { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || subdomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 420)
        .onAppear { isFocused = true }
    }
}
