import Foundation

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude, codex, pi, dsh, gemini, cursor, opencode

    /// 会话列表分组标题上用的名字（品牌名不翻译）
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .pi: return "Pi"
        case .dsh: return "DeepSeek Harness"
        case .gemini: return "Gemini CLI"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        }
    }
}

public enum SessionState: String, Codable, Sendable {
    case running, waiting, idle, ended
}

public struct Session: Identifiable, Equatable, Sendable {
    /// agent 提供的 session_id
    public let id: String
    public let agent: AgentKind
    public let cwd: String
    /// 已知时才有；配合 pidStartTime 防止 PID 复用误判
    public var pid: Int32?
    public var pidStartTime: Date?
    public var startedAt: Date
    public var lastActivityAt: Date
    public var state: SessionState

    public init(
        id: String, agent: AgentKind, cwd: String, pid: Int32? = nil, pidStartTime: Date? = nil,
        startedAt: Date, lastActivityAt: Date? = nil, state: SessionState = .running
    ) {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.pid = pid
        self.pidStartTime = pidStartTime
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt ?? startedAt
        self.state = state
    }

    /// 面板里显示的项目目录名
    public var projectName: String { (cwd as NSString).lastPathComponent }
}
