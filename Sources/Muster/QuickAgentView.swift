import MusterCore
import SwiftUI

/// The menu-bar surface performs frequent tasks directly; it keeps its own navigation.
struct QuickAgentView: View {
    @ObservedObject var workspace: AgentWorkspaceModel
    @ObservedObject var configuration: ConfigurationModel
    var onOpenWindow: (() -> Void)?
    @Environment(\.panelSurfaceVisible) private var isVisible

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: T.s2) {
                SegmentedControl(items: QuickAgentSection.allCases,
                    selection: Binding(get: { workspace.quickSection }, set: { workspace.selectQuickSection($0) }), label: \.title)
                    .frame(width: 132)
                agentPicker.frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    workspace.openQuickInWindow(skills: true)
                    onOpenWindow?()
                } label: {
                    Label(L10n.t("Skills"), systemImage: "arrow.up.right.square")
                }.buttonStyle(PillButtonStyle(kind: .quiet)).fixedSize()
                    .help(L10n.t("Manage skills in the main window"))
            }.padding(.horizontal, T.s3).padding(.vertical, T.s2)
            Hairline()
            if workspace.quickSection == .rules {
                InstructionsView(model: workspace.instructions,
                    agentID: workspace.quickRulesAgentID == "all" ? nil : workspace.quickRulesAgentID,
                    availableAgentIDs: Set(workspace.availableAgents.map(\.id)), compact: true)
            } else if let selected = configuration.selected, workspace.quickConfigurationTargets.contains(where: { $0.id == selected.id }) {
                ConfigurationView(model: configuration, showsAgentPicker: false, compact: true)
            } else if configuration.dirty, let selected = configuration.selected {
                VStack(alignment: .leading, spacing: T.s3) {
                    Text(selected.name).font(T.body.weight(.medium))
                    Text(L10n.t("The Agent is outside the current managed scope. Your configuration draft is still kept."))
                        .font(T.small).foregroundStyle(T.muted)
                    if workspace.selection.state.detected.contains(where: { $0.id == selected.id }) {
                        Button(L10n.t("Manage this Agent again")) { workspace.selection.setManaged(selected.id, true) }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                    Button(L10n.t("Discard")) { configuration.reload(); workspace.prepareQuickConfiguration() }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                    Spacer()
                }.padding(T.s3).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                EmptyState(title: L10n.t("No configurations found"),
                    message: L10n.t("Agents with existing configuration files show up here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { prepareConfiguration() }
        .onChange(of: isVisible) { _, _ in prepareConfiguration() }
        .onChange(of: workspace.availableAgents.map(\.id)) { _, _ in prepareConfiguration() }
    }

    @ViewBuilder private var agentPicker: some View {
        if workspace.quickSection == .rules {
            InlineSelect(items: ["all"] + workspace.availableAgents.map(\.id),
                label: { $0 == "all" ? L10n.t("All Agents") : (AgentRegistry.agent($0)?.name ?? $0) },
                selection: Binding(get: {
                    workspace.availableAgents.contains(where: { $0.id == workspace.quickRulesAgentID }) ? workspace.quickRulesAgentID : "all"
                }, set: { workspace.selectQuickRulesAgent($0) }))
                .disabled(workspace.isCheckingAgents)
        } else {
            let targets = workspace.quickConfigurationTargets
            let current = targets.first { $0.id == configuration.selected?.id }?.id
            let items = (current == nil ? [String?.none] : []) + targets.map { Optional($0.id) }
            InlineSelect(items: items, label: { id in targets.first { $0.id == id }?.name ?? L10n.t("Select Agent") },
                selection: Binding(get: { current }, set: { if let id = $0 { workspace.selectQuickConfigurationAgent(id) } }))
                .disabled(workspace.isCheckingAgents || targets.isEmpty)
        }
    }
    private func prepareConfiguration() {
        if isVisible && workspace.quickSection == .configuration { workspace.prepareQuickConfiguration() }
    }
}
