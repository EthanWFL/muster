import Testing
import Foundation
import MusterProtocol
@testable import MusterCore

@Suite struct ApprovalTimeoutTests {
    @Test func defaultTimeoutIs90Seconds() {
        #expect(ApprovalStore.defaultTimeout == 90)
        #expect(ApprovalStore(clock: ApprovalTestClock()).timeout == 90)
    }

    @Test func expiresOnlyAfterDeadline() {
        let clock = ApprovalTestClock()
        let store = ApprovalStore(clock: clock)
        submitBash(store, id: "a", command: "ls")
        clock.advance(89.9)
        #expect(store.expireDue().isEmpty)
        #expect(store.pendingCount == 1)
        clock.advance(0.1)
        let out = store.expireDue()
        #expect(out.count == 1)
        #expect(out[0].decision == .noDecision)
        #expect(out[0].call.status == .expired)
        #expect(out[0].requestIDs == ["a"])
        #expect(out[0].rowClosed)
        #expect(store.pendingCount == 0)
        #expect(store.history.map(\.status) == [.expired])
    }

    @Test func expiryIsNeverAnAllow() {
        let clock = ApprovalTestClock()
        let store = ApprovalStore(clock: clock)
        for i in 0..<5 { submitBash(store, id: "r\(i)", command: i % 2 == 0 ? "ls" : "sudo ls") }
        clock.advance(10_000)
        for r in store.expireDue() {
            #expect(r.decision == .noDecision)
            #expect(r.call.status == .expired)
        }
        #expect(store.pendingCount == 0)
    }

    @Test func timeoutIsConfigurable() {
        let clock = ApprovalTestClock()
        let store = ApprovalStore(clock: clock, timeout: 5)
        submitBash(store, id: "a", command: "ls")
        clock.advance(5)
        #expect(store.expireDue().count == 1)

        store.timeout = 30
        submitBash(store, id: "b", command: "ls")
        clock.advance(29)
        #expect(store.expireDue().isEmpty)
        clock.advance(1)
        #expect(store.expireDue().count == 1)
    }

    @Test func negativeTimeoutClampsToZero() {
        let clock = ApprovalTestClock()
        let store = ApprovalStore(clock: clock, timeout: -10)
        #expect(store.timeout == 0)
        submitBash(store, id: "a", command: "ls")
        #expect(store.expireDue().count == 1)
    }

    @Test func nextDeadlineTracksEarliest() {
        let clock = ApprovalTestClock()
        let store = ApprovalStore(clock: clock, timeout: 90)
        #expect(store.nextDeadline == nil)
        let t0 = clock.now()
        submitBash(store, id: "a", command: "ls a")
        clock.advance(10)
        submitBash(store, id: "b", command: "ls b")
        #expect(store.nextDeadline == t0.addingTimeInterval(90))
    }

    @Test func foldedMemberExpiresIndependently() {
        let clock = ApprovalTestClock()
        let store = ApprovalStore(clock: clock)
        submitBash(store, id: "a", command: "ls x")
        clock.advance(60)
        submitBash(store, id: "b", command: "ls x")
        clock.advance(30)
        let first = store.expireDue()
        #expect(first.count == 1)
        #expect(first[0].requestIDs == ["a"])
        #expect(!first[0].rowClosed)
        #expect(first[0].call.status == .pending)
        #expect(first[0].call.repeatCount == 1)
        #expect(store.pendingCount == 1)
        clock.advance(60)
        let second = store.expireDue()
        #expect(second[0].requestIDs == ["b"])
        #expect(second[0].rowClosed)
        #expect(store.pendingCount == 0)
    }

    @Test func decisionAfterExpiryFails() {
        let clock = ApprovalTestClock()
        let store = ApprovalStore(clock: clock)
        submitBash(store, id: "a", command: "ls")
        clock.advance(100)
        store.expireDue()
        #expect(throws: ApprovalError.notPending) { try store.allow(id: "a") }
        #expect(throws: ApprovalError.notPending) { try store.deny(id: "a", reason: "late") }
    }

    @Test func expireDueIsIdempotent() {
        let clock = ApprovalTestClock()
        let store = ApprovalStore(clock: clock)
        submitBash(store, id: "a", command: "ls")
        clock.advance(91)
        #expect(store.expireDue().count == 1)
        #expect(store.expireDue().isEmpty)
    }
}

@Suite struct ApprovalConnectionTests {
    @Test func droppedConnectionRemovesRowImmediately() {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", command: "ls")
        #expect(store.connectionDropped(requestID: "a"))
        #expect(store.pendingCount == 0)
        #expect(store.history.isEmpty)
        #expect(store.call(id: "a") == nil)
    }

    @Test func droppedUnknownRequestReturnsFalse() {
        let store = ApprovalStore(clock: ApprovalTestClock())
        #expect(!store.connectionDropped(requestID: "ghost"))
    }

    @Test func droppedAfterDecisionReturnsFalse() throws {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", command: "ls")
        try store.allow(id: "a")
        #expect(!store.connectionDropped(requestID: "a"))
    }

    @Test func droppingOneFoldedRequestKeepsTheRow() throws {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", command: "ls x")
        submitBash(store, id: "b", command: "ls x")
        submitBash(store, id: "c", command: "ls x")
        #expect(store.connectionDropped(requestID: "b"))
        #expect(store.pendingCount == 1)
        #expect(store.pending[0].repeatCount == 2)
        let r = try store.allow(id: "a")
        #expect(r.requestIDs == ["a", "c"])
    }

    @Test func droppingTheRowOwnerKeepsOthersAndRowIsStillAddressable() throws {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", command: "ls x")
        submitBash(store, id: "b", command: "ls x")
        #expect(store.connectionDropped(requestID: "a"))
        #expect(store.pendingCount == 1)
        let r = try store.deny(id: "b", reason: "no")
        #expect(r.requestIDs == ["b"])
    }

    @Test func droppingAllFoldedRequestsRemovesRow() {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", command: "ls x")
        submitBash(store, id: "b", command: "ls x")
        store.connectionDropped(requestID: "a")
        store.connectionDropped(requestID: "b")
        #expect(store.pendingCount == 0)
    }

    @Test func droppedRequestCanBeResubmittedAsFreshRow() {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", command: "ls x")
        store.connectionDropped(requestID: "a")
        guard case .queued(let call) = submitBash(store, id: "a2", command: "ls x") else {
            Issue.record("expected queued"); return
        }
        #expect(call.repeatCount == 1)
    }
}

@Suite struct ApprovalSessionEndTests {
    @Test func endSessionExpiresItsPendingRowsOnly() {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", session: "s1", command: "ls")
        submitBash(store, id: "b", session: "s2", command: "ls")
        let out = store.endSession("s1")
        #expect(out.count == 1)
        #expect(out[0].decision == .noDecision)
        #expect(out[0].call.status == .expired)
        #expect(store.pending.map(\.id) == ["b"])
    }

    @Test func endSessionClearsSimilarRules() throws {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", session: "s1", command: "git status")
        try store.allowSimilar(id: "a")
        #expect(store.similarRules(session: "s1").count == 1)
        store.endSession("s1")
        #expect(store.similarRules(session: "s1").isEmpty)
        guard case .queued = submitBash(store, id: "b", session: "s1", command: "git status") else {
            Issue.record("rule survived session end"); return
        }
    }

    @Test func endSessionKeepsOtherSessionsRules() throws {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", session: "s1", command: "git status")
        try store.allowSimilar(id: "a")
        store.endSession("s2")
        #expect(store.similarRules(session: "s1").count == 1)
    }
}
