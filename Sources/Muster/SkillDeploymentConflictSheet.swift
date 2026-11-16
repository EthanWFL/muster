import MusterCore
import SwiftUI

struct SkillDeploymentConflictSheet: View {
    @ObservedObject var model: SkillsModel
    let inspection: SkillDeploymentInspection
    @Environment(\.dismiss) private var dismiss

    private var canRelease: Bool { inspection.status == .missing || inspection.status == .changed }

    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text(L10n.t("Deployment needs attention")).font(.title2)
            Text((AgentRegistry.agent(inspection.deployment.targetID)?.name ?? inspection.deployment.targetID)
                 + " · " + (model.snapshot.skills.first { $0.id == inspection.deployment.skillID }?.name ?? ""))
                .font(T.body.weight(.medium))
            Text(inspection.deployment.path).font(T.monoMicro).textSelection(.enabled)
            Text(L10n.t(inspection.status == .missing
                ? "The deployed entry no longer exists. Muster still has its old record."
                : (inspection.status == .unreadable
                   ? "The deployed entry cannot be read. Check permissions, then refresh."
                   : "The deployed entry differs from Muster's record. Another tool or a manual edit may have replaced it.")))
                .font(T.body).fixedSize(horizontal: false, vertical: true)
            if inspection.fingerprint.hasPrefix("link:") {
                Text(L10n.t("Current link: %@", String(inspection.fingerprint.dropFirst(5))))
                    .font(T.monoMicro).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.t("Release only removes Muster's stale record, not files or links. Previous backups are retained; undo entries involving this path are invalidated."))
                .font(T.small).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            Text(L10n.t("Redeploy first releases the stale record, then opens a separate preview. Existing skill entries require backup confirmation. Canceling that preview leaves the entry unmanaged."))
                .font(T.small).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage {
                Text(error).font(T.small).foregroundStyle(T.red).fixedSize(horizontal: false, vertical: true)
            }
            if model.isBusy { ProgressView().controlSize(.small) }
            HStack {
                Button(L10n.t("Refresh")) { model.refreshDeploymentConflict() }.buttonStyle(PillButtonStyle(kind: .quiet))
                Spacer()
                Button(L10n.t("Cancel")) { dismiss() }.buttonStyle(PillButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                Button(L10n.t(inspection.status == .missing ? "Clear stale record" : "Release management only")) {
                    model.resolveDeploymentConflict(redeploy: false)
                }.buttonStyle(PillButtonStyle(kind: .secondary)).disabled(!canRelease)
                Button(L10n.t("Release and review redeployment")) {
                    model.resolveDeploymentConflict(redeploy: true)
                }.buttonStyle(PillButtonStyle(kind: .primary)).disabled(!canRelease)
            }.disabled(model.isBusy)
        }
        .padding(T.s4).frame(width: 650).background(T.bg)
        .interactiveDismissDisabled(model.isBusy)
    }
}
