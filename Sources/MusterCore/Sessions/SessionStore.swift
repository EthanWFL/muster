import Foundation

/// 根据 transcript 活跃时间推断会话状态；进程扫描结果由面板合并。
public final class SessionStore: @unchecked Sendable {
    private let clock: Clock
    private let policy: SessionPolicy
    private let probe: ProcessProbe
    private let lock = NSLock()
    private var records: [String: Session] = [:]

    public init(clock: Clock = SystemClock(), policy: SessionPolicy = .standard, probe: ProcessProbe = SystemProcessProbe()) {
        self.clock = clock
        self.policy = policy
        self.probe = probe
    }

    public func mergeDisk(_ sessions: [Session]) {
        lock.lock()
        defer { lock.unlock() }
        for session in sessions {
            if let existing = records[session.id] {
                records[session.id] = Session(
                    id: existing.id, agent: existing.agent,
                    cwd: existing.cwd.isEmpty ? session.cwd : existing.cwd,
                    pid: existing.pid, pidStartTime: existing.pidStartTime,
                    startedAt: min(existing.startedAt, session.startedAt),
                    lastActivityAt: max(existing.lastActivityAt, session.lastActivityAt))
            } else {
                records[session.id] = session
            }
        }
        prune(now: clock.now())
    }

    public func sessions() -> [Session] {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now()
        prune(now: now)
        return records.values.map { evaluated($0, now: now) }
            .sorted { $0.lastActivityAt != $1.lastActivityAt ? $0.lastActivityAt > $1.lastActivityAt : $0.id < $1.id }
    }

    public func session(id: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now()
        prune(now: now)
        return records[id].map { evaluated($0, now: now) }
    }

    private func evaluated(_ session: Session, now: Date) -> Session {
        var result = session
        let quiet = now.timeIntervalSince(session.lastActivityAt)
        if let pid = session.pid, !probe.isAlive(pid: pid, startTime: session.pidStartTime) {
            result.state = .ended
        } else if quiet > policy.endedAfterInactivity {
            result.state = .ended
        } else {
            result.state = quiet <= policy.diskRunningWindow ? .running : .idle
        }
        return result
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.retention)
        records = records.filter { $0.value.lastActivityAt >= cutoff }
    }
}
