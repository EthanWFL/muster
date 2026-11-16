import Foundation
import Testing
@testable import MusterCore

@Suite struct SessionActivityCountsTests {
    private func session(_ id: String, state: SessionState, alive: Bool) -> Session {
        var session = Session(id: id, agent: .claude, cwd: "/tmp/project", pid: alive ? 42 : nil,
                              startedAt: Date(), state: state)
        session.isProcessAlive = alive
        return session
    }

    @Test func countsOnlyLiveSessionsAndDoesNotInferActivityFromAProcess() {
        let counts = SessionActivityCounts(sessions: [
            session("active", state: .running, alive: true),
            session("idle", state: .idle, alive: true),
            session("unknown", state: .unknown, alive: true),
            session("proc-42", state: .running, alive: true),
            session("historical", state: .running, alive: false),
            session("ended", state: .ended, alive: true)
        ])
        #expect(counts.total == 4)
        #expect(counts.active == 1)
        #expect(counts.unknown == 2)
    }

    @Test func allExitedOrEmptySessionsShowZero() {
        let empty = SessionActivityCounts(sessions: [])
        let exited = SessionActivityCounts(sessions: [session("past", state: .idle, alive: false)])
        #expect(empty == exited)
        #expect(empty.total == 0 && empty.active == 0 && empty.unknown == 0)
    }

    @Test func scopeAndActivityChangesRecomputeBothCounts() {
        let first = session("first", state: .running, alive: true)
        let second = session("second", state: .idle, alive: true)
        #expect(SessionActivityCounts(sessions: [first, second]).total == 2)
        #expect(SessionActivityCounts(sessions: [second]).total == 1)
        #expect(SessionActivityCounts(sessions: [second]).active == 0)
    }
}
