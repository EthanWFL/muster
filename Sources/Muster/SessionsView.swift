import MusterCore
import SwiftUI

/// 「会话」页：本机正在跑的 agent 进程，按 agent 分组。
struct SessionsView: View {
    @ObservedObject var model: PanelModel

    private struct Group: Identifiable {
        let agent: AgentKind
        let sessions: [Session]
        var id: String { agent.rawValue }
    }

    private var groups: [Group] {
        let live = model.sessions.filter { $0.state != .ended }
        let byAgent = Dictionary(grouping: live) { $0.agent }
        return AgentKind.allCases.compactMap { agent in
            guard let items = byAgent[agent], !items.isEmpty else { return nil }
            return Group(agent: agent, sessions: items.sorted { $0.startedAt > $1.startedAt })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Active"), count: groups.reduce(0) { $0 + $1.sessions.count })
                .overlay(alignment: .trailing) {
                    Button { model.refreshSessions() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(T.faint)
                    .help(L10n.t("Rescan open sessions"))
                    .padding(.trailing, T.s3)
                }

            if groups.isEmpty {
                EmptyState(
                    title: L10n.t("No active sessions"),
                    message: L10n.t("Open sessions of installed agents show up here"))
            } else {
                ForEach(groups) { group in
                    agentHeader(group.agent, count: group.sessions.count)
                    Card {
                        ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                            SessionRow(model: model, session: session)
                            if index < group.sessions.count - 1 {
                                Hairline().padding(.leading, T.s3 + 15)
                            }
                        }
                    }
                }
            }
        }
    }

    private func agentHeader(_ agent: AgentKind, count: Int) -> some View {
        HStack(spacing: 6) {
            AgentLogo(
                agentID: agent.rawValue,
                mark: agent == .pi ? "π" : String(agent.displayName.prefix(1)),
                size: 14)
            Text(agent.displayName.uppercased())
                .font(T.section)
                .tracking(0.4)
                .foregroundStyle(T.muted)
            Text("\(count)").font(T.micro).monospacedDigit().foregroundStyle(T.faint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.s3)
        .padding(.top, T.s2)
        .padding(.bottom, 2)
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
                Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                    .font(T.monoMicro)
                    .foregroundStyle(T.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.cwd)
            }
            Spacer(minLength: T.s2)
            HStack(spacing: 4) {
                trailing
                    .font(T.small)
                    .foregroundStyle(session.state == .waiting ? T.amber : T.muted)
                    .lineLimit(1)
                Text("·")
                    .font(T.small)
                    .foregroundStyle(T.faint)
                Text(session.startedAt, style: .relative)
                    .font(T.micro)
                    .foregroundStyle(T.faint)
                    .fixedSize()
            }
            .frame(maxWidth: 190, alignment: .trailing)
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
            Text(L10n.t("Idle"))
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
