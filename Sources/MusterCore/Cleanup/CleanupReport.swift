import Foundation

public enum CleanupRefusal: Equatable, Sendable, CustomStringConvertible {
    case invalidPID(Int32)
    case ownProcess
    case processGone
    /// pid 还在，但启动时间与规划时不同：PID 被复用
    case identityChanged
    case notInSessionTree
    case uncertainOwnership
    case confirmationRequired
    case notTerminatedByUs
    case gracePeriodNotElapsed
    case unsafePath

    public var description: String {
        switch self {
        case .invalidPID(let pid): return "pid \(pid) 不允许操作 (pid <= 1)"
        case .ownProcess: return "不允许操作本 app 自身"
        case .processGone: return "进程已不存在"
        case .identityChanged: return "pid 已被另一个进程复用 (启动时间不一致)"
        case .notInSessionTree: return "进程不在 session 进程树内，且未二次确认"
        case .uncertainOwnership: return "归属置信度不足，且未二次确认"
        case .confirmationRequired: return "需要显式二次确认"
        case .notTerminatedByUs: return "尚未对该进程发过 SIGTERM"
        case .gracePeriodNotElapsed: return "SIGTERM 后不足 10 秒"
        case .unsafePath: return "目录路径不安全"
        }
    }
}

public enum CleanupOutcome: Equatable, Sendable {
    /// 命令已成功执行
    case done
    /// SIGTERM 已送达，不代表进程已退出
    case termSent
    case killSent
    case exited
    case refused(CleanupRefusal)
    case failed(String)
}

public struct CleanupEntry: Equatable, Sendable {
    public let itemID: String
    public let title: String
    public let commandText: String
    public let outcome: CleanupOutcome

    public init(itemID: String, title: String, commandText: String, outcome: CleanupOutcome) {
        self.itemID = itemID
        self.title = title
        self.commandText = commandText
        self.outcome = outcome
    }
}

/// R8：清理后的结果清单。
public struct CleanupReport: Equatable, Sendable {
    public var entries: [CleanupEntry] = []
    /// 已确认退出的进程此前占用的端口；不保证端口没有被其他进程重新占用。
    public var freedPorts: [Int] = []
    public var removedDirectories: [String] = []
    public var prunedRepositories: [String] = []
    public var reclaimedBytes: Int64 = 0
    /// 已发 SIGTERM、尚未确认退出的进程；10 秒后仍存活才可提示 SIGKILL
    public var awaitingExit: [ProcessTarget] = []

    public init() {}

    public var refusedCount: Int {
        entries.filter { if case .refused = $0.outcome { return true } else { return false } }.count
    }

    public var failedCount: Int {
        entries.filter { if case .failed = $0.outcome { return true } else { return false } }.count
    }
}
