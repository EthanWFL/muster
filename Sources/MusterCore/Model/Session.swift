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
    case running, idle, ended
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
    /// 工作目录当前的 git 分支；由面板在合并后填充
    public var branch: String?

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

    /// 在原目录里接着聊这个会话的命令。只有 transcript 里读到真实 id 的会话才有；
    /// 目前只确认过 Claude Code、Codex、Pi 的 resume 语法。
    public var resumeCommand: String? {
        guard !id.hasPrefix("proc-"), !id.isEmpty,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        let command: String
        switch agent {
        case .claude: command = "claude --resume \(id)"
        case .codex: command = "codex resume \(id)"
        case .pi: command = "pi --session \(id)"
        default: return nil
        }
        return cwd.isEmpty ? command : "cd " + Shell.quote(cwd) + " && " + command
    }
}

enum Shell {
    static func quote(_ path: String) -> String {
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@:")
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
