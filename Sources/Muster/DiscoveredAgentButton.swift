import MusterCore
import SwiftUI

/// Restricted visibility still needs a click response; disabling the Button also dims a bright logo.
struct DiscoveredAgentButton: View {
    @ObservedObject var model: SkillsModel
    let found: SkillDiscovery
    let agent: AgentDescriptor
    @State private var showsExplanation = false

    private var access: SkillsModel.DiscoveryAccess { model.discoveryAccess(found, agentID: agent.id) }
    private var sources: [SkillDiscovery] {
        model.discovered.filter { $0.suspendedID == nil && $0.isSameSkill(as: found) && $0.readers.contains(agent.id) }
    }

    var body: some View {
        Button {
            if access.canToggle, let target = model.deploymentTargets.first(where: { $0.id == agent.id }) {
                model.toggleDiscovered(found, target: target)
            } else {
                showsExplanation = true
            }
        } label: {
            AgentLogo(agentID: agent.id, mark: agent.id == "pi" ? "π" : String(agent.name.prefix(1)), size: 19)
                .saturation(access.enabled ? 1 : 0).opacity(access.enabled ? 1 : 0.35)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(T.card2))
        }
        .buttonStyle(InteractivePlainButtonStyle(pressedScale: 0.88))
        .disabled(model.isBusy)
        .help(agent.name + " · " + L10n.t(access.message))
        .accessibilityLabel(agent.name)
        .accessibilityValue(L10n.t(access.enabled ? "Enabled" : "Disabled"))
        .popover(isPresented: $showsExplanation) {
            VStack(alignment: .leading, spacing: T.s3) {
                Text(agent.name + " · " + found.name).font(T.section)
                Text(L10n.t(access.message)).font(T.body).fixedSize(horizontal: false, vertical: true)
                if !sources.isEmpty {
                    Text(L10n.t("Visible from these locations")).font(T.small).foregroundStyle(T.muted)
                    ScrollView {
                        VStack(alignment: .leading, spacing: T.s2) {
                            ForEach(sources) { source in
                                VStack(alignment: .leading, spacing: T.s1) {
                                    Text((source.path as NSString).abbreviatingWithTildeInPath)
                                        .font(T.monoMicro).textSelection(.enabled)
                                    Text(source.readers.map { AgentRegistry.agent($0)?.name ?? $0 }.joined(separator: " · "))
                                        .font(T.micro).foregroundStyle(T.muted)
                                    Button(L10n.t("Reveal in Finder")) { model.reveal(source.path) }
                                        .buttonStyle(PillButtonStyle(kind: .quiet))
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxHeight: 160)
                }
                HStack {
                    Spacer()
                    Button(L10n.t("Close")) { showsExplanation = false }.buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }.padding(T.s4).frame(width: 340).background(T.bg)
        }
    }
}
