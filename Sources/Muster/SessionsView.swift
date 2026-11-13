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
                    IconButton(symbol: "arrow.clockwise", label: L10n.t("Rescan open sessions")) {
                        model.refreshSessions()
                    }
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

    var body: some View {
        HStack(spacing: T.s2) {
            StatusDot(tone: tone)
                .accessibilityElement()
                .accessibilityLabel(session.state == .running ? L10n.t("Running") : L10n.t("Idle"))
            VStack(alignment: .leading, spacing: 0) {
                Text(session.projectName)
                    .font(T.body)
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                Text((session.cwd as NSString).abbreviatingWithTildeInPath
                     + (session.branch.map { " · " + $0 } ?? ""))
                    .font(T.monoMicro)
                    .foregroundStyle(T.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.cwd)
            }
            Spacer(minLength: T.s2)
            Text(session.startedAt, style: .relative)
                .font(T.micro)
                .foregroundStyle(T.faint)
                .fixedSize()
            IconButton(
                symbol: "terminal",
                label: L10n.t("Focus this session's terminal window. If it cannot be found, the folder path is copied.")
            ) { model.jumpToTerminal(session) }
            if session.resumeCommand != nil {
                IconButton(
                    symbol: "arrow.uturn.backward.circle",
                    label: L10n.t("Copy the command that resumes this session in its folder.")
                ) { model.copyResume(session) }
            }
        }
        .padding(.horizontal, T.s3)
        .frame(height: 40)
        .hoverHighlight()
        .contentShape(Rectangle())
    }

    private var tone: StatusTone {
        switch session.state {
        case .running: return .busy
        case .idle, .ended: return .idle
        }
    }
}
