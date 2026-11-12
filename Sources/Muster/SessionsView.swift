import MusterCore
import SwiftUI

struct SessionsView: View {
    @ObservedObject var model: PanelModel
    private static let pageSize = 8
    @State private var expanded = false

    private var active: [Session] {
        model.sessions
            .filter { $0.state != .ended }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private var shown: [Session] { expanded ? active : Array(active.prefix(Self.pageSize)) }
    private var hiddenCount: Int { active.count - shown.count }

    var body: some View {
        if active.isEmpty {
            EmptyState(
                title: L10n.t("No active sessions"),
                message: L10n.t("Sessions from Claude Code show up here"))
        } else {
            VStack(alignment: .leading, spacing: T.s2) {
                SectionTitle(text: L10n.t("Active"), count: active.count)
                Card {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                        SessionRow(model: model, session: session)
                        if index < shown.count - 1 { Hairline().padding(.leading, T.s3 + 15) }
                    }
                    if active.count > Self.pageSize {
                        Hairline().padding(.leading, T.s3 + 15)
                        CollapseRow(hiddenCount: hiddenCount, expanded: $expanded)
                    }
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
        HStack(spacing: T.s2) {
            StatusDot(tone: tone)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.projectName)
                    .font(T.body)
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                Text("\((session.cwd as NSString).abbreviatingWithTildeInPath) · \(session.agent.rawValue)")
                    .font(T.monoMicro)
                    .foregroundStyle(T.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: T.s2)
            trailing
                .font(T.small)
                .foregroundStyle(session.state == .waiting ? T.amber : T.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 150, alignment: .trailing)
            Button { model.jumpToTerminal(session) } label: {
                Image(systemName: "terminal").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(T.faint)
            .help(L10n.t("Focus this session's terminal window. If it cannot be found, the folder path is copied."))
        }
        .padding(.horizontal, T.s3)
        .frame(height: 40)
        .hoverHighlight()
        .contentShape(Rectangle())
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

    private var tone: StatusTone {
        switch session.state {
        case .running: return .busy
        case .waiting: return .waiting
        case .idle, .ended: return .idle
        }
    }
}
