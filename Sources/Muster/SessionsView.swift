import MusterCore
import SwiftUI

struct SessionsView: View {
    @ObservedObject var model: PanelModel

    private var visible: [Session] {
        model.sessions
            .filter { $0.state != .ended }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        if visible.isEmpty {
            VStack(spacing: 4) {
                Text(L10n.t("No active sessions")).fontWeight(.semibold)
                Text(L10n.t("Sessions from Claude Code show up here")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Active"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                ForEach(visible) { session in
                    SessionRow(model: model, session: session)
                }
            }
        }
    }
}

private struct SessionRow: View {
    @ObservedObject var model: PanelModel
    let session: Session

    private var pendingCount: Int { model.pending.filter { $0.sessionID == session.id }.count }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.projectName)
                Text("\((session.cwd as NSString).abbreviatingWithTildeInPath) · \(session.agent.rawValue)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            trailing
                .font(.subheadline)
                .foregroundStyle(session.state == .waiting ? Color.orange : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .trailing)
            Button { model.jumpToTerminal(session) } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L10n.t("Focus this session's terminal window. If it cannot be found, the folder path is copied."))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var trailing: some View {
        switch session.state {
        case .waiting where pendingCount > 0:
            Text(pendingCount == 1 ? L10n.t("1 approval") : L10n.t("%d approvals", pendingCount))
        case .running:
            Text(model.lastToolSummary(for: session.id) ?? L10n.t("Running"))
        default:
            Text(L10n.t("Idle")) + Text(" ") + Text(session.lastActivityAt, style: .relative)
        }
    }

    private var color: Color {
        switch session.state {
        case .running: return .green
        case .waiting: return .orange
        case .idle, .ended: return Color.secondary.opacity(0.6)
        }
    }
}
