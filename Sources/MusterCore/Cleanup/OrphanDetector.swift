import Foundation

/// 孤儿判定的阈值与内存上限，集中在这里。
public struct OrphanThresholds: Equatable, Sendable {
    /// 单核占用率（1.0 = 100%）
    public var cpuFraction = 0.6
    /// 需要持续的时长
    public var window: TimeInterval = 300
    /// 窗口内相邻两次采样的最大间隔，防止只靠首尾两个点就下结论
    public var maxSampleGap: TimeInterval = 60
    /// 采样最小间隔：更密的采样被丢弃，保证 capacity × minSampleInterval ≥ window
    public var minSampleInterval: TimeInterval = 5
    /// 每个进程保留的样本数上限（环形缓冲）
    public var sampleCapacity = 128
    /// 同时跟踪的进程数上限
    public var maxTracked = 256
    /// 窗口内「高于阈值」的时间占比至少达到此值
    public var sustainedFraction = 0.9

    public init() {}
}

public struct OrphanCandidate: Equatable, Sendable {
    public let identity: ProcessIdentity
    public let name: String?
    public let formerSessionID: String
    public let averageCPU: Double
    public let observedFor: TimeInterval
}

/// 找「曾属于某 session、现已被 launchd 收养、且 CPU 长时间居高不下」的进程。
/// 全部状态在内存里，按 pid + 启动时间区分进程，进程消失或 pid 被复用时丢弃。
public final class OrphanDetector: @unchecked Sendable {
    private struct Sample {
        let time: Date
        let cpu: Double
    }

    private struct Track {
        var sessionID: String
        var agentID: String
        var name: String?
        var ppid: Int32
        var samples: RingBuffer<Sample>?
    }

    public let thresholds: OrphanThresholds
    private let clock: Clock
    private let lock = NSLock()
    private var tracks: [ProcessIdentity: Track] = [:]
    private var managedAgentIDs: Set<String>?

    public init(clock: Clock = SystemClock(), thresholds: OrphanThresholds = OrphanThresholds()) {
        self.clock = clock
        self.thresholds = thresholds
    }

    public var trackedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tracks.count
    }

    /// A parent exiting is precisely when its tracked children still need observation.
    public func needsSampling(sessions: [Session]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !tracks.isEmpty || sessions.contains { $0.pid != nil && $0.state != .ended && (managedAgentIDs?.contains($0.agent.rawValue) ?? true) }
    }

    public func restrictToAgents(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        managedAgentIDs = ids
        tracks = tracks.filter { ids.contains($0.value.agentID) }
    }

    /// 喂入一次快照：登记 session 树内的进程，更新已登记进程的采样。
    public func observe(snapshot: ProcessSnapshot, sessions: [Session]) {
        lock.lock(); defer { lock.unlock() }

        // 1. 淘汰：进程已退出，或 pid 被别的进程复用
        for identity in Array(tracks.keys) {
            guard let record = snapshot.processes[identity.pid],
                  startTimesMatch(record.startTime, identity.startTime, tolerance: 1) else {
                tracks[identity] = nil
                continue
            }
            update(identity, with: record, at: snapshot.takenAt)
        }

        // 2. 登记：目前位于 session 进程树内的进程
        for session in sessions where managedAgentIDs?.contains(session.agent.rawValue) ?? true {
            guard let root = snapshot.rootRecord(for: session) else { continue }
            for (pid, record) in snapshot.processes where snapshot.isDescendant(pid, of: root.pid) {
                guard let identity = record.identity else { continue }
                if tracks[identity] == nil {
                    guard tracks.count < thresholds.maxTracked else { continue }
                    tracks[identity] = Track(sessionID: session.id, agentID: session.agent.rawValue, name: record.name, ppid: record.ppid, samples: nil)
                }
            }
        }
    }

    private func update(_ identity: ProcessIdentity, with record: ProcessRecord, at time: Date) {
        guard var track = tracks[identity] else { return }
        track.ppid = record.ppid
        if record.ppid == 1, let cpu = record.cpuTimeSeconds {
            var ring = track.samples ?? RingBuffer<Sample>(capacity: thresholds.sampleCapacity)
            if let last = ring.last, time.timeIntervalSince(last.time) < thresholds.minSampleInterval {
                // 采样太密，丢弃
            } else {
                ring.append(Sample(time: time, cpu: cpu))
            }
            track.samples = ring
        } else {
            // 只统计被收养之后的 CPU；还有父进程时历史作废
            track.samples = nil
        }
        tracks[identity] = track
    }

    public func candidates() -> [OrphanCandidate] {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now()
        var result: [OrphanCandidate] = []
        for (identity, track) in tracks where track.ppid == 1 {
            guard let samples = track.samples?.elements, let stats = evaluate(samples, now: now) else { continue }
            result.append(OrphanCandidate(
                identity: identity, name: track.name, formerSessionID: track.sessionID,
                averageCPU: stats.average, observedFor: stats.duration))
        }
        return result.sorted { $0.identity.pid < $1.identity.pid }
    }

    private func evaluate(_ all: [Sample], now: Date) -> (average: Double, duration: TimeInterval)? {
        guard let last = all.last, now.timeIntervalSince(last.time) <= thresholds.maxSampleGap else { return nil }
        let windowStart = now.addingTimeInterval(-thresholds.window)
        guard let anchorIndex = all.lastIndex(where: { $0.time <= windowStart }) else { return nil }
        let span = Array(all[anchorIndex...])
        guard span.count >= 2 else { return nil }

        var aboveTime: TimeInterval = 0
        var totalTime: TimeInterval = 0
        for (a, b) in zip(span, span.dropFirst()) {
            let dt = b.time.timeIntervalSince(a.time)
            guard dt > 0, dt <= thresholds.maxSampleGap else { return nil }
            totalTime += dt
            if max(0, b.cpu - a.cpu) / dt > thresholds.cpuFraction { aboveTime += dt }
        }
        guard totalTime >= thresholds.window else { return nil }
        let average = max(0, span[span.count - 1].cpu - span[0].cpu) / totalTime
        guard average > thresholds.cpuFraction, aboveTime / totalTime >= thresholds.sustainedFraction else { return nil }
        return (average, totalTime)
    }
}
