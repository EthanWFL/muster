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
                    windowToolbar
                    Hairline()
                    if workspace.section == .skills {
                        SkillsView(model: workspace.skills, agentID: workspace.agentID)
                    } else {
                        ScrollView {
                            if workspace.section == .rules {
                                InstructionsView(model: workspace.instructions, agentID: workspace.agentID == "all" ? nil : workspace.agentID,
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

    private var windowToolbar: some View {
        HStack(spacing: T.s3) {
            InlineSelect(items: ["all"] + workspace.availableAgents.map(\.id),
                label: { $0 == "all" ? L10n.t("All Agents") : (AgentRegistry.agent($0)?.name ?? $0) },
                selection: Binding(get: {
                    workspace.availableAgents.contains(where: { $0.id == workspace.agentID }) ? workspace.agentID : "all"
                }, set: { workspace.selectAgent($0) }))
                .disabled(workspace.isCheckingAgents)
            IconButton(symbol: "arrow.clockwise", label: L10n.t("Refresh installed Agents"), isBusy: workspace.isCheckingAgents) { workspace.refreshAgents() }
            Spacer(minLength: 0)
            SegmentedControl(items: AgentSection.allCases, selection: Binding(get: { workspace.section }, set: { workspace.selectSection($0) }),
                             label: \.title).frame(width: 260)
        }.padding(T.s3)
    }

    private var configuration: some View {
        AgentConfigurationContent(workspace: workspace, configuration: workspace.configuration)
    }

}

private struct AgentConfigurationContent: View {
    @ObservedObject var workspace: AgentWorkspaceModel
    @ObservedObject var configuration: ConfigurationModel
    @ViewBuilder var body: some View {
        if workspace.agentID == "all" {
            AgentConfigurationOverview(workspace: workspace, configuration: configuration)
        } else if configuration.targets.contains(where: { $0.id == workspace.agentID }) {
            ConfigurationView(model: configuration, showsAgentPicker: false)
        } else {
            EmptyState(title: L10n.t("No configurations found"), message: L10n.t("Agents with existing configuration files show up here."))
        }
    }
}

private struct AgentConfigurationOverview: View {
    @ObservedObject var workspace: AgentWorkspaceModel
    @ObservedObject var configuration: ConfigurationModel
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
            if targets.isEmpty {
                EmptyState(title: L10n.t("No configurations found"), message: L10n.t("Agents with existing configuration files show up here."))
            }
            ForEach(targets) { target in
                Button { workspace.selectAgent(target.id) } label: {
                    HStack {
                        AgentLogo(agentID: target.id, mark: String(target.name.prefix(1)))
                        VStack(alignment: .leading, spacing: T.s1) {
                            Text(target.name).font(T.body.weight(.medium))
                            Text((target.path as NSString).abbreviatingWithTildeInPath).font(T.monoMicro).foregroundStyle(T.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(T.muted)
                    }.padding(T.s3).foregroundStyle(T.fg).background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
                }.buttonStyle(InteractivePlainButtonStyle(pressedScale: 1))
            }
        }
    }
}
