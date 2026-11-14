import SwiftUI
import MusterCore

struct AgentSelectionSettingsView: View {
    @ObservedObject var selection: AgentSelectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            HStack {
                SectionTitle(text: L10n.t("Managed Agents"), count: selection.state.managedIDs.count)
                Spacer()
                IconButton(symbol: "arrow.clockwise", label: L10n.t("Refresh installed Agents"), isBusy: selection.isChecking) { selection.refresh() }
            }
            Text(L10n.t("Choose which Agents Muster manages across rules, sessions, skills, configuration and cleanup."))
                .font(T.small).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true).padding(.horizontal, T.s3)
            Card {
                ForEach(Array(AgentRegistry.all.enumerated()), id: \.element.id) { index, agent in
                    SettingsRow(label: agent.name,
                        hint: L10n.t(selection.isChecking ? "Checking…" : (selection.state.detected.contains(where: { $0.id == agent.id }) ? "Detected on this Mac" : "Not detected on this Mac"))) {
                        MiniSwitch(isOn: Binding(get: { selection.manages(agent.id) }, set: { selection.setManaged(agent.id, $0) }), label: agent.name)
                            .disabled(selection.isChecking || !selection.state.hasDetected)
                    }
                    if index < AgentRegistry.all.count - 1 { Hairline() }
                }
                Hairline()
                HStack(spacing: T.s2) {
                    Button(L10n.t("Select detected")) { selection.selectDetected() }.buttonStyle(PillButtonStyle(kind: .secondary))
                    Button(L10n.t("Clear selection")) { selection.selectNone() }.buttonStyle(PillButtonStyle(kind: .quiet))
                    Spacer(minLength: 0)
                    Button(L10n.t("Follow installations")) { selection.followDetected() }
                        .buttonStyle(PillButtonStyle(kind: selection.isAutomatic ? .secondary : .quiet))
                        .disabled(selection.isAutomatic)
                }.padding(T.s3).disabled(selection.isChecking || !selection.state.hasDetected)
            }
            Text(L10n.t(selection.isAutomatic
                ? "Automatically includes detected Agents. Changing a switch saves a custom list; new installations will not be added to that list automatically."
                : "Custom Agent list saved. Changes apply immediately and are kept after restarting Muster."))
                .font(T.small).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true).padding(.horizontal, T.s3)
            Text(L10n.t("Turning an Agent off hides its records and stops new operations for it. Files, history, drafts and existing skill deployments are kept. Selected Agents that are not installed can still have their historical sessions shown."))
                .font(T.small).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true).padding(.horizontal, T.s3)
        }
        .onAppear { if !selection.state.hasDetected { selection.refresh() } }
    }
}
