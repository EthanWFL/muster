import SwiftUI

/// One destination table drives this sidebar and the management content area.
struct ManagementSidebar: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(model.workspaceDestinations) { destination in
                    row(destination, hint: shortcutHint(destination))
                }
            } header: {
                Text(L10n.t("Workspace")).font(T.section)
            }
            Section {
                row(.wheel, hint: nil)
                row(.settings, hint: "⌘,")
            } header: {
                Text(L10n.t("Configuration")).font(T.section)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(T.bg)
        .tint(T.accent)
        .frame(width: 208)
        .frame(maxHeight: .infinity)
    }

    private var selection: Binding<PanelModel.Destination?> {
        Binding(get: { model.destination },
                set: { if let destination = $0 { model.select(destination) } })
    }

    private func row(_ destination: PanelModel.Destination, hint: String?) -> some View {
        HStack(spacing: T.s2) {
            Image(systemName: destination.symbol)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(destination.sidebarTitle)
                .font(T.body)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let hint {
                Text(hint)
                    .font(T.micro)
                    .foregroundStyle(T.muted)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: T.rowSingle)
        .tag(destination)
        .accessibilityLabel(destination.sidebarTitle)
    }

    private func shortcutHint(_ destination: PanelModel.Destination) -> String? {
        guard case .workspace(let tab) = destination,
              let index = model.orderedTabs.firstIndex(of: tab) else { return nil }
        return "⌘\(index + 1)"
    }
}
