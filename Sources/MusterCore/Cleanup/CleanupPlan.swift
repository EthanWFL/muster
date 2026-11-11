import Foundation

/// 一条「将要执行的命令」。展示文本由 argv 派生，二者不可能不一致（R7）。
public struct PlannedCommand: Equatable, Sendable {
    public let argv: [String]
    public let cwd: String?

    public init(argv: [String], cwd: String? = nil) {
        self.argv = argv
        self.cwd = cwd
    }

    /// 仅供展示；执行永远用 `argv`，不经 shell。
    public var displayText: String {
        let text = argv.map(shellQuote).joined(separator: " ")
        guard let cwd else { return text }
        return "(cd \(shellQuote(cwd)) && \(text))"
    }
}

/// 规划时锁定的进程身份与归属证据。执行层会拿它和实时状态再比一遍。
public struct ProcessTarget: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 在 session 树内监听端口
        case listener
        /// 曾属于 session、现已被 launchd 收养且 CPU 居高不下
        case orphan
    }

    public let identity: ProcessIdentity
    public let name: String?
    public let commandLine: String?
    public let kind: Kind
    public let sessionID: String
    public let ports: [Int]
    public let score: OwnershipScore
    /// 规划时是否在 session 进程树内（执行层会重新判定，不信任此值）
    public let inSessionTreeAtPlan: Bool

    public init(
        identity: ProcessIdentity, name: String?, commandLine: String?, kind: Kind, sessionID: String,
        ports: [Int], score: OwnershipScore, inSessionTreeAtPlan: Bool
    ) {
        self.identity = identity
        self.name = name
        self.commandLine = commandLine
        self.kind = kind
        self.sessionID = sessionID
        self.ports = ports
        self.score = score
        self.inSessionTreeAtPlan = inSessionTreeAtPlan
    }
}

public enum CleanupAction: Equatable, Sendable {
    /// 只发 SIGTERM
    case terminate(ProcessTarget)
    /// 只清 worktree 元数据
    case pruneWorktrees(repoRoot: String)
    /// 删除 worktree 目录：独立动作，必须显式确认
    case removeWorktreeDirectory(repoRoot: String, path: String)

    /// 展示与执行共用的命令。kill 由 `ProcessSignaller` 执行，pid 与信号取自同一个 target。
    public var command: PlannedCommand {
        switch self {
        case .terminate(let target):
            return PlannedCommand(argv: ["kill", CleanupSignal.term.flag, String(target.identity.pid)])
        case .pruneWorktrees(let repoRoot):
            return PlannedCommand(argv: ["git", "worktree", "prune"], cwd: repoRoot)
        case .removeWorktreeDirectory(let repoRoot, let path):
            return PlannedCommand(argv: ["git", "worktree", "remove", path], cwd: repoRoot)
        }
    }

    public var isUncertain: Bool {
        if case .terminate(let target) = self { return target.score.isUncertain }
        return false
    }

    /// 需要用户逐项二次确认才会执行
    public var needsExplicitConfirmation: Bool {
        switch self {
        case .terminate(let target):
            return target.score.isUncertain || !target.inSessionTreeAtPlan || target.kind == .orphan
        case .pruneWorktrees:
            return false
        case .removeWorktreeDirectory:
            return true
        }
    }

    var stableID: String {
        switch self {
        case .terminate(let t):
            return "kill:\(t.identity.pid):\(Int(t.identity.startTime.timeIntervalSince1970))"
        case .pruneWorktrees(let repo):
            return "prune:\(repo)"
        case .removeWorktreeDirectory(_, let path):
            return "rmdir:\(path)"
        }
    }
}

public struct CleanupItem: Identifiable, Equatable, Sendable {
    public let action: CleanupAction
    public let title: String

    public init(action: CleanupAction, title: String) {
        self.action = action
        self.title = title
    }

    public var id: String { action.stableID }
    public var command: PlannedCommand { action.command }
    public var isUncertain: Bool { action.isUncertain }
    public var needsExplicitConfirmation: Bool { action.needsExplicitConfirmation }

    /// 不确定、需二次确认的项一律不默认勾选
    public var isPreselected: Bool { !isUncertain && !needsExplicitConfirmation }

    public var confidence: Double? {
        if case .terminate(let target) = action { return target.score.confidence }
        return nil
    }
}

public struct CleanupPlan: Equatable, Sendable {
    public let createdAt: Date
    public let items: [CleanupItem]

    public init(createdAt: Date, items: [CleanupItem]) {
        self.createdAt = createdAt
        self.items = items
    }

    public var preselectedIDs: Set<String> { Set(items.filter(\.isPreselected).map(\.id)) }

    /// UI 的「将执行的命令」列表，与执行器用的是同一批 item。
    public var commandTexts: [String] { items.map { $0.command.displayText } }
}
