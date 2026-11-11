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

    func event(_ id: String, _ kind: SessionHookEvent.Kind, pid: Int32? = nil, cwd: String? = nil) -> SessionHookEvent {
        SessionHookEvent(sessionID: id, cwd: cwd, pid: pid, kind: kind, at: clock.now())
    }

    @Test func diskOnlyRecentSessionIsRunningThenIdle() {
        let store = makeStore()
        store.mergeDisk([diskSession("a", ageSeconds: 5)])
        #expect(store.session(id: "a")?.state == .running)
        clock.advance(SessionPolicy.defaultDiskRunningWindow + 5)
        #expect(store.session(id: "a")?.state == .idle)
    }

    @Test func hookStateOverridesDiskInference() {
        let store = makeStore()
        // Disk says: transcript is 10 minutes old, which alone would be idle.
        store.mergeDisk([diskSession("a", ageSeconds: 600)])
        #expect(store.session(id: "a")?.state == .idle)
        store.apply(event("a", .waiting))
        #expect(store.session(id: "a")?.state == .waiting)
        // A later disk scan must not change the hook-decided state.
        store.mergeDisk([diskSession("a", ageSeconds: 0)])
        #expect(store.session(id: "a")?.state == .waiting)
    }

    @Test func stateMachineRunningWaitingIdleEnded() {
        let store = makeStore()
        store.apply(event("a", .started, cwd: "/work/app"))
        #expect(store.session(id: "a")?.state == .running)
        clock.advance(1)
        store.apply(event("a", .waiting))
        #expect(store.session(id: "a")?.state == .waiting)
        clock.advance(1)
        store.apply(event("a", .idle))
        #expect(store.session(id: "a")?.state == .idle)
        clock.advance(1)
        store.apply(event("a", .ended))
        #expect(store.session(id: "a")?.state == .ended)
    }

    @Test func endsAfterInactivityThreshold() {
        let store = makeStore()
        store.apply(event("a", .idle, cwd: "/work/app"))
        clock.advance(SessionPolicy.defaultEndedAfterInactivity - 1)
        #expect(store.session(id: "a")?.state == .idle)
        clock.advance(2)
        #expect(store.session(id: "a")?.state == .ended)
    }

    @Test func endsWhenProcessIsGone() {
        let store = makeStore()
        store.apply(event("a", .started, pid: 4242, cwd: "/work/app"))
        #expect(store.session(id: "a")?.state == .running)
        probe.kill(4242)
        #expect(store.session(id: "a")?.state == .ended)
    }

    @Test func laterEventRevivesEndedSession() {
        let store = makeStore()
        store.apply(event("a", .ended, cwd: "/work/app"))
        #expect(store.session(id: "a")?.state == .ended)
        clock.advance(10)
        store.apply(event("a", .started))
        #expect(store.session(id: "a")?.state == .running)
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

    @Test func keepsOnlyLastThreeToolSummaries() {
        let store = makeStore()
        for i in 1...5 {
            clock.advance(1)
            store.apply(event("a", .toolCall(summary: "Bash: step \(i)"), cwd: "/work/app"))
        }
        #expect(store.toolSummaries(for: "a") == ["Bash: step 3", "Bash: step 4", "Bash: step 5"])
    }

    @Test func summariesAreSingleLineAndBounded() {
        let policy = SessionPolicy(maxSummaryLength: 20)
        let store = makeStore(policy: policy)
        store.apply(event("a", .toolCall(summary: "Bash: first line\nsecond line that is long"), cwd: "/work/app"))
        let summary = store.toolSummaries(for: "a").first ?? ""
        #expect(!summary.contains("\n"))
        #expect(summary.count <= 20)
    }

    @Test func hookEventFillsCwdAndKeepsDiskSession() {
        let store = makeStore()
        store.mergeDisk([diskSession("a", ageSeconds: 120, cwd: "/work/app")])
        store.apply(event("a", .toolCall(summary: "Read: x"), pid: 77))
        let s = store.session(id: "a")
        #expect(s?.cwd == "/work/app")
        #expect(s?.pid == 77)
        #expect(s?.state == .running)
    }

    @Test func sessionsAreSortedByLatestActivity() {
        let store = makeStore()
        store.mergeDisk([diskSession("older", ageSeconds: 300), diskSession("newer", ageSeconds: 10)])
        #expect(store.sessions().map(\.id) == ["newer", "older"])
    }
}
