import Foundation

/// pid + 启动时间才能唯一标识一个进程（防 PID 复用）。
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startTime: Date

    public init(pid: Int32, startTime: Date) {
        self.pid = pid
        self.startTime = startTime
    }
}

public struct ProcessRecord: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var startTime: Date?
    public var cwd: String?
    public var name: String?
    public var executablePath: String?
    /// 累计 CPU 时间（用户+系统，秒）；OrphanDetector 用差值算占用率
    public var cpuTimeSeconds: Double?

    public init(
        pid: Int32, ppid: Int32, startTime: Date? = nil, cwd: String? = nil, name: String? = nil,
        executablePath: String? = nil, cpuTimeSeconds: Double? = nil
    ) {
        self.pid = pid
        self.ppid = ppid
        self.startTime = startTime
        self.cwd = cwd
        self.name = name
        self.executablePath = executablePath
        self.cpuTimeSeconds = cpuTimeSeconds
    }

    public var identity: ProcessIdentity? {
        startTime.map { ProcessIdentity(pid: pid, startTime: $0) }
    }
}

/// 进程表读取抽象。真实实现走 libproc，测试注入桩。
public protocol ProcessTable: Sendable {
    func allPIDs() -> [Int32]
    func record(for pid: Int32) -> ProcessRecord?
}

public func startTimesMatch(_ a: Date?, _ b: Date?, tolerance: TimeInterval) -> Bool {
    guard let a, let b else { return false }
    return abs(a.timeIntervalSince(b)) <= tolerance
}

public struct ProcessSnapshot: Sendable {
    public let takenAt: Date
    public let processes: [Int32: ProcessRecord]
    /// 来自 `ps`；取不到时为空，不影响其他判断
    public let commandLines: [Int32: String]

    public init(takenAt: Date, processes: [Int32: ProcessRecord], commandLines: [Int32: String] = [:]) {
        self.takenAt = takenAt
        self.processes = processes
        self.commandLines = commandLines
    }

    /// 从 pid 向上的祖先链（不含自身），带环保护。
    public func ancestors(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var seen: Set<Int32> = [pid]
        var current = processes[pid]?.ppid ?? 0
        while current > 0, !seen.contains(current), result.count < 256 {
            result.append(current)
            seen.insert(current)
            current = processes[current]?.ppid ?? 0
        }
        return result
    }

    /// 严格后代：pid == root 返回 false。
    public func isDescendant(_ pid: Int32, of root: Int32) -> Bool {
        pid != root && ancestors(of: pid).contains(root)
    }

    /// session 根进程必须仍是当初那个进程，否则（PID 复用）不承认其进程树。
    public func rootRecord(for session: Session) -> ProcessRecord? {
        guard let pid = session.pid, pid > 1, let record = processes[pid],
              let actual = record.startTime else { return nil }
        if let expected = session.pidStartTime {
            return abs(actual.timeIntervalSince(expected)) <= 1 ? record : nil
        }
        // 没记录启动时间：复用的 pid 只可能晚于 session 开始，据此排除
        return actual <= session.startedAt.addingTimeInterval(5) ? record : nil
    }

    public func isInTree(of session: Session, pid: Int32) -> Bool {
        guard let root = rootRecord(for: session) else { return false }
        return isDescendant(pid, of: root.pid)
    }
}
