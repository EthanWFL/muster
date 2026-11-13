import Foundation
import Testing
@testable import MusterCore

@Suite struct SessionReconciliationTests {
    let clock = SessionsTestClock()
    let probe = SessionsTestProbe()

    func transcript(_ id: String, age: TimeInterval = 0, agent: AgentKind = .claude) -> Session {
        Session(id: id, agent: agent, cwd: "/work", startedAt: clock.now().addingTimeInterval(-120),
                lastActivityAt: clock.now().addingTimeInterval(-age))
    }

    func process(_ pid: Int32, age: TimeInterval = 60, agent: AgentKind = .claude) -> Session {
        let start = clock.now().addingTimeInterval(-age)
        return Session(id: "proc-\(pid)", agent: agent, cwd: "/work", pid: pid,
                       pidStartTime: start, startedAt: start, state: .unknown)
    }

    @Test func uniqueAssociationPersistsAndTracksExit() {
        let store = SessionStore(clock: clock, probe: probe)
        let disk = transcript("a"), live = process(42)
        #expect(store.refresh(transcripts: [disk], processes: [live]).count == 1)
        #expect(store.session(id: "a")?.pid == 42)
        probe.kill(42)
        _ = store.refresh(transcripts: [disk], processes: [])
        #expect(store.session(id: "a")?.state == .ended)
    }

    @Test func sameDirectoryMultipleProcessesAreNotGuessed() {
        let store = SessionStore(clock: clock, probe: probe)
        let list = store.refresh(transcripts: [transcript("a"), transcript("b")], processes: [process(42), process(43)])
        #expect(list.count == 4)
        #expect(list.filter(\.hasTranscript).allSatisfy { $0.pid == nil && !$0.isProcessAlive })
        #expect(list.filter { !$0.hasTranscript }.allSatisfy { $0.state == .unknown })
    }

    @Test func newAmbiguityInvalidatesAnInferredAssociation() {
        let store = SessionStore(clock: clock, probe: probe)
        _ = store.refresh(transcripts: [transcript("a")], processes: [process(42)])
        let list = store.refresh(transcripts: [transcript("a"), transcript("b")], processes: [process(42)])
        #expect(list.count == 3)
        #expect(store.session(id: "a")?.pid == nil)
        #expect(store.session(id: "b")?.pid == nil)
    }

    @Test func oldTranscriptCannotBeAttachedToNewProcess() {
        let store = SessionStore(clock: clock, probe: probe)
        let list = store.refresh(transcripts: [transcript("a", age: 120)], processes: [process(42)])
        #expect(list.count == 2)
        #expect(store.session(id: "a")?.pid == nil)
    }

    @Test func liveButQuietProcessNeverEndsBecauseOfTranscriptTimeout() {
        let store = SessionStore(clock: clock, probe: probe)
        let disk = transcript("a"), live = process(42)
        _ = store.refresh(transcripts: [disk], processes: [live])
        clock.advance(25 * 60 * 60)
        let list = store.refresh(transcripts: [], processes: [live])
        #expect(list.count == 1)
        #expect(list.first?.state == .idle)
        #expect(list.first?.isProcessAlive == true)
    }

    @Test func equalTranscriptIDsFromDifferentAgentsStaySeparate() {
        let store = SessionStore(clock: clock, probe: probe)
        let list = store.refresh(transcripts: [transcript("same"), transcript("same", agent: .codex)], processes: [])
        #expect(list.count == 2)
        #expect(Set(list.map(\.key)).count == 2)
    }

    @Test func quietReminderRequiresObservedActivityAndDebounces() {
        var monitor = SessionActivityMonitor()
        var session = transcript("a")
        session.pid = 42
        session.isProcessAlive = true
        session.state = .idle
        #expect(monitor.newlyQuiet([session], now: clock.now().addingTimeInterval(120)).isEmpty)
        session.state = .running
        #expect(monitor.newlyQuiet([session], now: clock.now()).isEmpty)
        session.state = .idle
        #expect(monitor.newlyQuiet([session], now: clock.now().addingTimeInterval(45)).isEmpty)
        #expect(monitor.newlyQuiet([session], now: clock.now().addingTimeInterval(60)).count == 1)
        #expect(monitor.newlyQuiet([session], now: clock.now().addingTimeInterval(90)).isEmpty)
        session.state = .running
        session.lastActivityAt = clock.now().addingTimeInterval(100)
        _ = monitor.newlyQuiet([session], now: session.lastActivityAt)
        session.state = .idle
        #expect(monitor.newlyQuiet([session], now: clock.now().addingTimeInterval(160)).count == 1)
    }

    @Test func unassociatedTranscriptsNeverNotify() {
        var monitor = SessionActivityMonitor()
        var session = transcript("a")
        _ = monitor.newlyQuiet([session], now: clock.now())
        session.state = .idle
        #expect(monitor.newlyQuiet([session], now: clock.now().addingTimeInterval(120)).isEmpty)
    }
}
