import Foundation
import Testing
@testable import MusterCore

@Suite struct OrphanDetectorTests {
    let t0 = CleanupFixture.t0
    let session = CleanupFixture.session

    private func snapshot(at offset: TimeInterval, childPPID: Int32, childCPU: Double, childStart: TimeInterval = 10)
        -> ProcessSnapshot
    {
        let records = [
            CleanupFixture.record(100, ppid: 50, start: 0, name: "claude"),
            CleanupFixture.record(200, ppid: childPPID, start: childStart, name: "node", cpu: childCPU),
        ]
        return ProcessSnapshot(
            takenAt: t0.addingTimeInterval(offset),
            processes: Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) }))
    }

    /// 先在树内登记，再被收养，之后每 10 秒采样一次。
    private func run(
        detector: OrphanDetector, clock: CleanupTestClock, until end: TimeInterval, cpuRate: Double
    ) {
        detector.observe(snapshot: snapshot(at: 0, childPPID: 100, childCPU: 0), sessions: [session])
        var t: TimeInterval = 10
        while t <= end {
            detector.observe(snapshot: snapshot(at: t, childPPID: 1, childCPU: cpuRate * t), sessions: [session])
            t += 10
        }
        clock.set(t0.addingTimeInterval(end))
    }

    @Test func sustainedHighCPUOrphanIsReported() {
        let clock = CleanupTestClock(t0)
        let detector = OrphanDetector(clock: clock)
        run(detector: detector, clock: clock, until: 400, cpuRate: 0.9)
        let found = detector.candidates()
        #expect(found.count == 1)
        #expect(found.first?.identity.pid == 200)
        #expect(found.first?.formerSessionID == "s1")
        #expect((found.first?.averageCPU ?? 0) > 0.6)
    }

    @Test func lowCPUIsNotReported() {
        let clock = CleanupTestClock(t0)
        let detector = OrphanDetector(clock: clock)
        run(detector: detector, clock: clock, until: 400, cpuRate: 0.1)
        #expect(detector.candidates().isEmpty)
    }

    @Test func tooShortObservationIsNotReported() {
        let clock = CleanupTestClock(t0)
        let detector = OrphanDetector(clock: clock)
        run(detector: detector, clock: clock, until: 200, cpuRate: 0.9)
        #expect(detector.candidates().isEmpty)
    }

    @Test func stillHavingAParentIsNotAnOrphan() {
        let clock = CleanupTestClock(t0)
        let detector = OrphanDetector(clock: clock)
        detector.observe(snapshot: snapshot(at: 0, childPPID: 100, childCPU: 0), sessions: [session])
        for i in 1...40 {
            let t = TimeInterval(i * 10)
            detector.observe(snapshot: snapshot(at: t, childPPID: 100, childCPU: 0.9 * t), sessions: [session])
        }
        clock.set(t0.addingTimeInterval(400))
        #expect(detector.candidates().isEmpty)
    }

    @Test func neverOwnedProcessIsNeverTracked() {
        let clock = CleanupTestClock(t0)
        let detector = OrphanDetector(clock: clock)
        // 进程一开始就是 ppid 1，从未在 session 树内
        for i in 0...40 {
            let t = TimeInterval(i * 10)
            detector.observe(snapshot: snapshot(at: t, childPPID: 1, childCPU: 0.9 * t), sessions: [session])
        }
        clock.set(t0.addingTimeInterval(400))
        #expect(detector.trackedCount == 0)
        #expect(detector.candidates().isEmpty)
    }

    @Test func pidReuseDropsTheTrack() {
        let clock = CleanupTestClock(t0)
        let detector = OrphanDetector(clock: clock)
        detector.observe(snapshot: snapshot(at: 0, childPPID: 100, childCPU: 0), sessions: [session])
        #expect(detector.trackedCount >= 1)
        // 200 号现在是另一个启动时间不同的进程
        let reused = ProcessSnapshot(
            takenAt: t0.addingTimeInterval(10),
            processes: [200: CleanupFixture.record(200, ppid: 1, start: 5000, cpu: 1)])
        detector.observe(snapshot: reused, sessions: [session])
        #expect(detector.trackedCount == 0)
    }

    @Test func staleSamplesDoNotProduceCandidates() {
        let clock = CleanupTestClock(t0)
        let detector = OrphanDetector(clock: clock)
        run(detector: detector, clock: clock, until: 400, cpuRate: 0.9)
        clock.advance(3600)  // 采样早已停止
        #expect(detector.candidates().isEmpty)
    }
}

@Suite struct RingBufferTests {
    @Test func overwritesOldestAndStaysBounded() {
        var ring = RingBuffer<Int>(capacity: 3)
        for i in 1...10 { ring.append(i) }
        #expect(ring.count == 3)
        #expect(ring.elements == [8, 9, 10])
        #expect(ring.last == 10)
    }

    @Test func partiallyFilledKeepsOrder() {
        var ring = RingBuffer<Int>(capacity: 5)
        ring.append(1); ring.append(2)
        #expect(ring.elements == [1, 2])
    }
}
