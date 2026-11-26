import MusterCore
import SwiftUI

struct AgentWorkspaceView: View {
    @ObservedObject var workspace: AgentWorkspaceModel
    var onOpenWindow: (() -> Void)?
    @Environment(\.panelPresentation) private var presentation

    var body: some View {
        Group {
            if presentation == .popover {
                QuickAgentView(workspace: workspace, configuration: workspace.configuration, onOpenWindow: onOpenWindow)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        SegmentedControl(items: AgentSection.allCases,
                                         selection: Binding(get: { workspace.section },
                                                            set: { workspace.selectSection($0) }),
                                         label: \.title)
                            .frame(maxWidth: 420)
                        Spacer(minLength: 0)
                    }
                    .padding(T.s3)
                    Hairline()
                    if workspace.section == .skills {
                        SkillsView(model: workspace.skills, agentID: "all", managedAgents: workspace.managedAgents)
                    } else {
                        ScrollView {
                            if workspace.section == .rules {
                                InstructionsView(model: workspace.instructions,
                                    availableAgentIDs: Set(workspace.availableAgents.map(\.id)))
                                    .padding(T.s4)
                            } else {
                                configuration.padding(T.s4)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(T.bg)
        .onAppear { workspace.load(syncWindowSelection: presentation == .window) }
        .alert(L10n.t("Save configuration changes?"), isPresented: Binding(get: {
            workspace.confirmsAgentChange && workspace.agentChangeInQuickPanel == (presentation == .popover)
        }, set: { workspace.confirmsAgentChange = $0 })) {
            Button(L10n.t("Save and switch")) { workspace.resolveAgentChange(save: true) }.disabled(!workspace.configuration.canWrite)
            Button(L10n.t("Discard and switch"), role: .destructive) { workspace.resolveAgentChange(save: false) }
            Button(L10n.t("Cancel"), role: .cancel) { workspace.cancelAgentChange() }
        } message: { Text(L10n.t("The current Agent has unsaved configuration changes.")) }
    }

    private var configuration: some View {
        AgentConfigurationContent(workspace: workspace, configuration: workspace.configuration)
    }

}

private struct AgentConfigurationContent: View {
    @ObservedObject var workspace: AgentWorkspaceModel
    @ObservedObject var configuration: ConfigurationModel
    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            if workspace.agentID != "all" {
                Button { workspace.selectAgent("all") } label: {
                    Label(L10n.t("All configurations"), systemImage: "chevron.left")
                }.buttonStyle(PillButtonStyle(kind: .quiet))
            }
            content
        }
    }
    @ViewBuilder private var content: some View {
        if workspace.agentID == "all" {
            AgentConfigurationOverview(workspace: workspace, configuration: configuration)
        } else if !workspace.availableAgents.contains(where: { $0.id == workspace.agentID }) {
            EmptyState(title: AgentRegistry.agent(workspace.agentID)?.name ?? workspace.agentID,
                       message: L10n.t("This Agent is selected in Settings but was not detected on this Mac."))
        } else if configuration.targets.contains(where: { $0.id == workspace.agentID }) {
            ConfigurationView(model: configuration, showsAgentPicker: false)
        } else {
            EmptyState(title: L10n.t("No configurations found"), message: L10n.t("No configuration file was found for this Agent."))
        }
    }
}

struct AgentConfigurationOverview: View {
    @ObservedObject var workspace: AgentWorkspaceModel
    @ObservedObject var configuration: ConfigurationModel
    var onSelect: ((String) -> Void)? = nil
    private var targets: [AgentConfiguration] {
        let ids = Set(workspace.availableAgents.map(\.id))
        return configuration.targets.filter { ids.contains($0.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text(L10n.t("Agent configuration")).font(T.section).foregroundStyle(T.muted)
            if configuration.dirty, let selected = configuration.selected, !targets.contains(where: { $0.id == selected.id }) {
                Text(L10n.t("The Agent is outside the current managed scope. Your configuration draft is still kept."))
                    .font(T.small).foregroundStyle(T.amber)
                HStack {
                    Text(selected.name).font(T.body)
                    if workspace.selection.state.detected.contains(where: { $0.id == selected.id }) {
                        Button(L10n.t("Manage this Agent again")) { workspace.selection.setManaged(selected.id, true) }.buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                    Button(L10n.t("Discard")) { configuration.reload() }.buttonStyle(PillButtonStyle(kind: .quiet))
                }
                if let error = configuration.errorMessage { Text(error).font(T.small).foregroundStyle(T.red) }
            }
            if workspace.managedAgents.isEmpty {
                EmptyState(title: L10n.t("No Agents selected for Muster."), message: L10n.t("Choose Agents in Settings → Agent management."))
            }
            ForEach(workspace.managedAgents) { agent in
                let target = targets.first { $0.id == agent.id }
                Button { (onSelect ?? workspace.selectAgent)(agent.id) } label: {
                    HStack {
                        AgentLogo(agentID: agent.id, mark: String(agent.name.prefix(1)))
                        VStack(alignment: .leading, spacing: T.s1) {
                            Text(agent.name).font(T.body.weight(.medium))
                            Text(target.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                                 ?? L10n.t(workspace.availableAgents.contains { $0.id == agent.id }
                                           ? "No configuration file was found for this Agent."
                                           : "This Agent is selected in Settings but was not detected on this Mac."))
                                .font(T.monoMicro).foregroundStyle(T.muted).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(T.muted)
                    }.padding(T.s3).foregroundStyle(T.fg).background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
                }.buttonStyle(InteractivePlainButtonStyle(pressedScale: 1))
            }
        }
    }
}
