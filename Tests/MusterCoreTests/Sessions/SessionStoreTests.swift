import Foundation
import Testing
@testable import MusterCore

@Suite("SessionStore")
struct SessionStoreTests {
    let clock = SessionsTestClock()
    let probe = SessionsTestProbe()

    func makeStore(policy: SessionPolicy = .standard) -> SessionStore {
        SessionStore(clock: clock, policy: policy, probe: probe)
    }

    func diskSession(_ id: String, ageSeconds: TimeInterval, cwd: String = "/work/app") -> Session {
        let t = clock.now().addingTimeInterval(-ageSeconds)
        return Session(id: id, agent: .claude, cwd: cwd, startedAt: t.addingTimeInterval(-60), lastActivityAt: t, state: .idle)
    }

    @Test func recentSessionBecomesIdleThenEnds() {
        let store = makeStore()
        store.mergeDisk([diskSession("a", ageSeconds: 5)])
        #expect(store.session(id: "a")?.state == .running)
        clock.advance(SessionPolicy.defaultDiskRunningWindow + 5)
        #expect(store.session(id: "a")?.state == .idle)
        clock.advance(SessionPolicy.defaultEndedAfterInactivity)
        #expect(store.session(id: "a")?.state == .ended)
    }

    @Test func newTranscriptActivityRevivesAnInactiveSession() {
        let store = makeStore()
        store.mergeDisk([diskSession("a", ageSeconds: SessionPolicy.defaultEndedAfterInactivity + 1)])
        #expect(store.session(id: "a")?.state == .ended)
        store.mergeDisk([diskSession("a", ageSeconds: 0)])
        #expect(store.session(id: "a")?.state == .running)
    }

    @Test func endsWhenProcessIsGone() {
        let store = makeStore()
        var session = diskSession("a", ageSeconds: 0)
        session.pid = 4242
        store.mergeDisk([session])
        #expect(store.session(id: "a")?.state == .running)
        probe.kill(4242)
        #expect(store.session(id: "a")?.state == .ended)
    }

    @Test func dropsSessionsOlderThan24Hours() {
        let store = makeStore()
        store.mergeDisk([
            diskSession("old", ageSeconds: SessionPolicy.defaultRetention + 60),
            diskSession("fresh", ageSeconds: 60),
        ])
        #expect(store.sessions().map(\.id) == ["fresh"])
        clock.advance(SessionPolicy.defaultRetention)
        #expect(store.sessions().isEmpty)
    }

    @Test func rescansKeepEarliestStartAndLatestActivity() {
        let store = makeStore()
        let initial = diskSession("a", ageSeconds: 120, cwd: "")
        store.mergeDisk([initial])
        let latest = diskSession("a", ageSeconds: 0)
        store.mergeDisk([latest])
        store.mergeDisk([initial])
        let session = store.session(id: "a")
        #expect(session?.startedAt == initial.startedAt)
        #expect(session?.lastActivityAt == latest.lastActivityAt)
        #expect(session?.cwd == latest.cwd)
        #expect(session?.state == .running)
    }

    @Test func sessionsAreSortedByLatestActivity() {
        let store = makeStore()
        store.mergeDisk([diskSession("older", ageSeconds: 300), diskSession("newer", ageSeconds: 10)])
        #expect(store.sessions().map(\.id) == ["newer", "older"])
    }
}
