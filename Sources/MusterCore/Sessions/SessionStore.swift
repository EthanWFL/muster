import Foundation

/// Merges sessions inferred from disk with live hook events. Hook events win.
///
/// State machine: `running -> waiting -> idle -> ended`. `ended` is reached when a hook says so,
/// when the recorded process is gone, or after `SessionPolicy.endedAfterInactivity` without activity.
/// A session with no hook events is judged by transcript activity alone.
///
/// Only the last `maxToolSummaries` tool-call summaries per session are kept, as strings.
/// No conversation text is stored. Sessions older than `SessionPolicy.retention` are dropped.
public final class SessionStore: @unchecked Sendable {
    private struct Record {
        var id: String
        var agent: AgentKind
        var cwd: String
        var pid: Int32?
        var pidStartTime: Date?
        var startedAt: Date
        var lastActivityAt: Date
        /// nil until the first hook event; once set, disk data never changes the state.
        var hookState: SessionState?
        var endedAt: Date?
        var summaries: [String] = []
    }

    private let clock: Clock
    private let policy: SessionPolicy
    private let probe: ProcessProbe
    private let lock = NSLock()
    private var records: [String: Record] = [:]

    public init(clock: Clock = SystemClock(), policy: SessionPolicy = .standard, probe: ProcessProbe = SystemProcessProbe()) {
        self.clock = clock
        self.policy = policy
        self.probe = probe
    }

    // MARK: - Input

    /// Adds sessions inferred from disk. For sessions already known, disk data only fills gaps
    /// (empty cwd, earlier start, later activity); it never changes pid or state.
    public func mergeDisk(_ sessions: [Session]) {
        lock.lock()
        defer { lock.unlock() }
        for s in sessions {
            if var r = records[s.id] {
                if r.cwd.isEmpty { r.cwd = s.cwd }
                r.startedAt = min(r.startedAt, s.startedAt)
                r.lastActivityAt = max(r.lastActivityAt, s.lastActivityAt)
                records[s.id] = r
            } else {
                records[s.id] = Record(
                    id: s.id, agent: s.agent, cwd: s.cwd, pid: s.pid, pidStartTime: s.pidStartTime,
                    startedAt: s.startedAt, lastActivityAt: s.lastActivityAt, hookState: nil)
            }
        }
        prune(now: clock.now())
    }

    /// Applies a live hook event. It overrides whatever the disk said.
    public func apply(_ event: SessionHookEvent) {
        lock.lock()
        defer { lock.unlock() }
        var r = records[event.sessionID] ?? Record(
            id: event.sessionID, agent: event.agent, cwd: event.cwd ?? "", pid: nil, pidStartTime: nil,
            startedAt: event.at, lastActivityAt: event.at, hookState: nil)
        if let cwd = event.cwd, !cwd.isEmpty { r.cwd = cwd }
        if let pid = event.pid {
            if pid != r.pid { r.pidStartTime = event.pidStartTime } else if let t = event.pidStartTime { r.pidStartTime = t }
            r.pid = pid
        }
        r.startedAt = min(r.startedAt, event.at)
        r.lastActivityAt = max(r.lastActivityAt, event.at)

        // A later non-ending event revives a session that was marked ended (for example a resumed session).
        if let ended = r.endedAt, event.at > ended, event.kind != .ended { r.endedAt = nil }

        switch event.kind {
        case .started:
            r.hookState = .running
        case .toolCall(let summary):
            r.hookState = .running
            let cleaned = sanitize(summary)
            if !cleaned.isEmpty {
                r.summaries.append(cleaned)
                if r.summaries.count > policy.maxToolSummaries {
                    r.summaries.removeFirst(r.summaries.count - policy.maxToolSummaries)
                }
            }
        case .waiting:
            r.hookState = .waiting
        case .idle:
            r.hookState = .idle
        case .ended:
            r.hookState = .ended
            r.endedAt = max(r.endedAt ?? event.at, event.at)
        }
        records[event.sessionID] = r
        prune(now: clock.now())
    }

    // MARK: - Output

    /// Current sessions, newest activity first. State is evaluated at call time.
    public func sessions() -> [Session] {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now()
        prune(now: now)
        return records.values
            .map { build($0, now: now) }
            .sorted { $0.lastActivityAt != $1.lastActivityAt ? $0.lastActivityAt > $1.lastActivityAt : $0.id < $1.id }
    }

    public func session(id: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now()
        prune(now: now)
        return records[id].map { build($0, now: now) }
    }

    /// The most recent tool-call summaries, oldest first.
    public func toolSummaries(for id: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return records[id]?.summaries ?? []
    }

    // MARK: - Internals

    private func build(_ r: Record, now: Date) -> Session {
        Session(
            id: r.id, agent: r.agent, cwd: r.cwd, pid: r.pid, pidStartTime: r.pidStartTime,
            startedAt: r.startedAt, lastActivityAt: r.lastActivityAt, state: state(of: r, now: now))
    }

    private func state(of r: Record, now: Date) -> SessionState {
        if r.endedAt != nil { return .ended }
        if let pid = r.pid, !probe.isAlive(pid: pid, startTime: r.pidStartTime) { return .ended }
        let quiet = now.timeIntervalSince(r.lastActivityAt)
        if quiet > policy.endedAfterInactivity { return .ended }
        if let hook = r.hookState { return hook }
        return quiet <= policy.diskRunningWindow ? .running : .idle
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.retention)
        records = records.filter { $0.value.lastActivityAt >= cutoff }
    }

    /// One line, bounded length. Summary strings only.
    private func sanitize(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(policy.maxSummaryLength))
    }
}
