import SwiftUI

private enum WorkspaceSettingsSection: String, CaseIterable, Identifiable {
    case cloudflare = "Cloudflare"
    case runtimePaths = "Runtime Paths"
    case configuration = "Configuration"
    case environment = "Environment"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cloudflare:
            return "icloud"
        case .runtimePaths:
            return "gearshape.2"
        case .configuration:
            return "doc.text"
        case .environment:
            return "stethoscope"
        }
    }

    var summary: String {
        switch self {
        case .cloudflare:
            return "Tunnel credentials, DNS API access, and cloudflared control."
        case .runtimePaths:
            return "Binary paths, log files, and local runtime validation."
        case .configuration:
            return "Generated service config files and quick edits."
        case .environment:
            return "Machine health checks and service diagnostics."
        }
    }
}

public struct WorkspaceSettingsView: View {
    @State private var selection: WorkspaceSettingsSection = .cloudflare

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sectionPicker
            Divider()

            selectedSectionView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Low-frequency configuration and system tools, organized in one place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sectionPicker: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            spacing: 12
        ) {
            ForEach(WorkspaceSettingsSection.allCases) { section in
                sectionCard(section)
            }
        }
        .padding(16)
        .background(.bar)
    }

    private func sectionCard(_ section: WorkspaceSettingsSection) -> some View {
        Button {
            selection = section
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: section.icon)
                    .font(.headline)
                    .foregroundStyle(selection == section ? Color.accentColor : .secondary)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 4) {
                    Text(section.rawValue)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(section.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .background(cardBackground(for: section))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cardBackground(for section: WorkspaceSettingsSection) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selection == section ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        selection == section ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            )
    }

    @ViewBuilder
    private var selectedSectionView: some View {
        switch selection {
        case .cloudflare:
            CloudflareView()
        case .runtimePaths:
            RuntimePathsView()
        case .configuration:
            ConfigPreviewView()
        case .environment:
            EnvironmentChecksView()
        }
    }
}
