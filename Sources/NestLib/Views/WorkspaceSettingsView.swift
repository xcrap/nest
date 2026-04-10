import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case environment = "Environment"
    case runtimePaths = "Paths"
    case configuration = "Config"
    case cloudflare = "Cloudflare"

    var id: String { rawValue }
}

public struct WorkspaceSettingsView: View {
    @State private var selection: SettingsTab = .environment

    private let orderedTabs: [SettingsTab] = [
        .environment,
        .runtimePaths,
        .configuration,
        .cloudflare
    ]

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $selection) {
                    ForEach(orderedTabs) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 400)
                .environment(\.layoutDirection, .leftToRight)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            Group {
                switch selection {
                case .environment:
                    EnvironmentChecksView()
                case .runtimePaths:
                    RuntimePathsView()
                case .configuration:
                    ConfigPreviewView()
                case .cloudflare:
                    CloudflareView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
