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
                Spacer(minLength: 0)
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
                rulesContent
            } else {
                if workspace.quickConfigurationAgentID != "all" {
                    HStack {
                        Button { workspace.selectQuickConfigurationAgent("all") } label: {
                            Label(L10n.t("All configurations"), systemImage: "chevron.left")
                        }.buttonStyle(PillButtonStyle(kind: .quiet))
                        Spacer()
                        Text(AgentRegistry.agent(workspace.quickConfigurationAgentID)?.name ?? workspace.quickConfigurationAgentID)
                            .font(T.small).foregroundStyle(T.muted).lineLimit(1)
                    }.padding(.horizontal, T.s3).padding(.vertical, T.s1)
                }
                configurationContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { prepareConfiguration() }
        .onChange(of: isVisible) { _, _ in prepareConfiguration() }
        .onChange(of: workspace.managedAgents.map(\.id)) { _, _ in prepareConfiguration() }
        .onChange(of: workspace.availableAgents.map(\.id)) { _, _ in prepareConfiguration() }
    }

    private var rulesContent: some View {
        InstructionsView(model: workspace.instructions,
            availableAgentIDs: Set(workspace.availableAgents.map(\.id)), compact: true)
    }

    @ViewBuilder private var configurationContent: some View {
        if let selected = configuration.selected, selected.id == workspace.quickConfigurationAgentID,
           workspace.quickConfigurationTargets.contains(where: { $0.id == selected.id }) {
            ConfigurationView(model: configuration, showsAgentPicker: false, compact: true)
        } else if configuration.dirty, let selected = configuration.selected {
            VStack(alignment: .leading, spacing: T.s3) {
                Text(selected.name).font(T.body)
                Text(L10n.t("The Agent is outside the current managed scope. Your configuration draft is still kept."))
                    .font(T.small).foregroundStyle(T.amber)
                if workspace.selection.state.detected.contains(where: { $0.id == selected.id }) {
                    Button(L10n.t("Manage this Agent again")) { workspace.selection.setManaged(selected.id, true) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Button(L10n.t("Discard")) { configuration.reload(); workspace.prepareQuickConfiguration() }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                Spacer()
            }.padding(T.s3).frame(maxWidth: .infinity, alignment: .leading)
        } else if workspace.quickConfigurationAgentID == "all" {
            ScrollView {
                AgentConfigurationOverview(workspace: workspace, configuration: configuration,
                                           onSelect: workspace.selectQuickConfigurationAgent).padding(T.s3)
            }
        } else {
            EmptyState(title: AgentRegistry.agent(workspace.quickConfigurationAgentID)?.name ?? L10n.t("No configurations found"),
                       message: L10n.t(workspace.availableAgents.contains { $0.id == workspace.quickConfigurationAgentID }
                                      ? "No configuration file was found for this Agent."
                                      : "This Agent is selected in Settings but was not detected on this Mac."))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func prepareConfiguration() {
        if isVisible && workspace.quickSection == .configuration { workspace.prepareQuickConfiguration() }
    }
}
