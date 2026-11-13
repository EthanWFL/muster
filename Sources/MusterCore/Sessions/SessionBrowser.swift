import Foundation

public enum SessionGrouping: String, CaseIterable, Sendable {
    case agent, project
}

public enum SessionActivityFilter: String, CaseIterable, Sendable {
    case all, active, quiet, unknown

    public func includes(_ session: Session) -> Bool {
        guard session.state != .ended else { return false }
        switch self {
        case .all: return true
        case .active: return session.state == .running
        case .quiet: return session.state == .idle
        case .unknown: return session.state == .unknown
        }
    }
}

public struct SessionGroup: Identifiable, Sendable {
    public let id: String
    public let agent: AgentKind?
    public let projectPath: String?
    public let sessions: [Session]
}

/// Search and presentation share one result, including keyboard selection order.
/// Project grouping uses complete working-directory paths, without filesystem reads.
public struct SessionBrowser: Sendable {
    public var query: String
    public var activity: SessionActivityFilter
    public var grouping: SessionGrouping

    public init(query: String = "", activity: SessionActivityFilter = .all, grouping: SessionGrouping = .agent) {
        self.query = query
        self.activity = activity
        self.grouping = grouping
    }

    public func groups(in sessions: [Session], titles: [String: String] = [:]) -> [SessionGroup] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = sessions.filter { session in
            guard activity.includes(session) else { return false }
            let text = [session.cwd, session.projectName, session.agent.displayName, session.agent.rawValue,
                        session.branch ?? "", session.id, session.pid.map(String.init) ?? "", titles[session.key] ?? ""].joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }.sorted {
            if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.key < $1.key
        }
        switch grouping {
        case .agent:
            let groups = Dictionary(grouping: matches, by: \.agent)
            return AgentKind.allCases.compactMap { agent in
                groups[agent].map { SessionGroup(id: "agent:" + agent.rawValue, agent: agent, projectPath: nil, sessions: $0) }
            }
        case .project:
            let groups = Dictionary(grouping: matches) { session in
                session.cwd.isEmpty ? "unknown:" + session.key : "project:" + (session.cwd as NSString).standardizingPath
            }
            return groups.map { key, sessions in
                SessionGroup(id: key, agent: nil,
                    projectPath: sessions[0].cwd.isEmpty ? nil : (sessions[0].cwd as NSString).standardizingPath,
                    sessions: sessions)
            }.sorted { $0.id < $1.id }
        }
    }
}
