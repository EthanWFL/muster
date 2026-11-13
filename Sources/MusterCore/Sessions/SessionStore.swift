import Foundation

/// Owns transcript/process reconciliation so identity survives successive scans.
public final class SessionStore: @unchecked Sendable {
    private let clock: Clock
    private let policy: SessionPolicy
    private let probe: ProcessProbe
    private let lock = NSLock()
    private var records: [String: Session] = [:]
    private var unmatchedProcesses: [Session] = []
    private var inferredKeys: Set<String> = []

    public init(clock: Clock = SystemClock(), policy: SessionPolicy = .standard, probe: ProcessProbe = SystemProcessProbe()) {
        self.clock = clock
        self.policy = policy
        self.probe = probe
    }

    public func mergeDisk(_ sessions: [Session]) {
        lock.lock(); defer { lock.unlock() }
        mergeDiskLocked(sessions)
    }

    /// Publish one coherent scan, rather than racing process and transcript updates.
    public func refresh(transcripts: [Session], processes: [Session]) -> [Session] {
        lock.lock(); defer { lock.unlock() }
        mergeDiskLocked(transcripts)
        let now = clock.now()
        let previousLinks = records
        // Reconsider inferred links when new candidates appear. Keep dead identities
        // so an unchanged transcript does not turn a closed process back into a session.
        for key in inferredKeys {
            guard var record = records[key], let pid = record.pid,
                  processes.contains(where: { $0.agent == record.agent && $0.cwd == record.cwd }),
                  probe.isAlive(pid: pid, startTime: record.pidStartTime) else { continue }
            record.pid = nil
            record.pidStartTime = nil
            records[key] = record
        }
        var matched: Set<String> = []
        for process in processes {
            guard let pid = process.pid, let start = process.pidStartTime else { continue }
            if records.values.contains(where: {
                $0.agent == process.agent && $0.pid == pid && $0.pidStartTime == start
            }) {
                matched.insert(process.key)
                continue
            }
            let peers = processes.filter { $0.agent == process.agent && $0.cwd == process.cwd }
            let candidates = records.values.filter {
                $0.agent == process.agent && $0.cwd == process.cwd && $0.pid == nil
                    && $0.lastActivityAt >= start.addingTimeInterval(-1)
                    && (evaluated($0, now: now).state != .ended
                        || (previousLinks[$0.key]?.pid == pid && previousLinks[$0.key]?.pidStartTime == start))
            }
            guard peers.count == 1, candidates.count == 1, var record = candidates.first else { continue }
            record.pid = pid
            record.pidStartTime = start
            record.startedAt = min(record.startedAt, process.startedAt)
            records[record.key] = record
            inferredKeys.insert(record.key)
            matched.insert(process.key)
        }
        unmatchedProcesses = processes.filter { !matched.contains($0.key) }.map {
            var process = $0
            process.state = .unknown
            return process
        }
        return sessionsLocked(now: now)
    }

    public func sessions() -> [Session] {
        lock.lock(); defer { lock.unlock() }
        return sessionsLocked(now: clock.now())
    }

    public func session(id: String, agent: AgentKind? = nil) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return sessionsLocked(now: clock.now()).first { $0.id == id && (agent == nil || $0.agent == agent) }
    }

    private func mergeDiskLocked(_ sessions: [Session]) {
        for session in sessions {
            if var existing = records[session.key] {
                // New activity may be a resumed session in a different process.
                if session.lastActivityAt > existing.lastActivityAt, let pid = existing.pid,
                   !probe.isAlive(pid: pid, startTime: existing.pidStartTime) {
                    existing.pid = nil
                    existing.pidStartTime = nil
                }
                records[session.key] = Session(
                    id: existing.id, agent: existing.agent,
                    cwd: existing.cwd.isEmpty ? session.cwd : existing.cwd,
                    pid: existing.pid, pidStartTime: existing.pidStartTime,
                    startedAt: min(existing.startedAt, session.startedAt),
                    lastActivityAt: max(existing.lastActivityAt, session.lastActivityAt))
            } else { records[session.key] = session }
        }
        prune(now: clock.now())
    }

    private func sessionsLocked(now: Date) -> [Session] {
        prune(now: now)
        return (Array(records.values) + unmatchedProcesses).map { evaluated($0, now: now) }
            .sorted { $0.lastActivityAt != $1.lastActivityAt ? $0.lastActivityAt > $1.lastActivityAt : $0.key < $1.key }
    }

    private func evaluated(_ session: Session, now: Date) -> Session {
        var result = session
        let quiet = now.timeIntervalSince(session.lastActivityAt)
        result.isProcessAlive = session.pid.map { probe.isAlive(pid: $0, startTime: session.pidStartTime) } ?? false
        if session.pid != nil && !result.isProcessAlive {
            result.state = .ended
        } else if !session.hasTranscript {
            result.state = .unknown
        } else if !result.isProcessAlive && quiet > policy.endedAfterInactivity {
            result.state = .ended
        } else {
            result.state = quiet <= policy.diskRunningWindow ? .running : .idle
        }
        return result
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.retention)
        records = records.filter { _, record in
            record.lastActivityAt >= cutoff
                || (record.pid.map { probe.isAlive(pid: $0, startTime: record.pidStartTime) } ?? false)
        }
        inferredKeys.formIntersection(records.keys)
    }
}
