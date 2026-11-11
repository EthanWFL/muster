import Testing
import Foundation
import MusterProtocol
@testable import MusterCore

@Suite struct ApprovalStateMachineTests {
    func make() -> (ApprovalStore, ApprovalTestClock) {
        let clock = ApprovalTestClock()
        return (ApprovalStore(clock: clock), clock)
    }

    @Test func submitQueuesPendingCall() {
        let (store, _) = make()
        let outcome = submitBash(store, id: "a", command: "ls")
        guard case .queued(let call) = outcome else { Issue.record("expected queued"); return }
        #expect(call.status == .pending)
        #expect(call.repeatCount == 1)
        #expect(call.risk == .low)
        #expect(store.pendingCount == 1)
    }

    @Test func allowMovesToAllowedOnce() throws {
        let (store, _) = make()
        submitBash(store, id: "a", command: "ls")
        let r = try store.allow(id: "a")
        #expect(r.call.status == .allowed)
        #expect(r.decision == .allow)
        #expect(r.requestIDs == ["a"])
        #expect(r.rowClosed)
        #expect(store.pendingCount == 0)
        #expect(store.history.map(\.id) == ["a"])
        #expect(throws: ApprovalError.notPending) { try store.allow(id: "a") }
        #expect(throws: ApprovalError.notPending) { try store.deny(id: "a", reason: "no") }
    }

    @Test func unknownIDIsNotFound() {
        let (store, _) = make()
        #expect(throws: ApprovalError.notFound) { try store.allow(id: "nope") }
        #expect(throws: ApprovalError.notFound) { try store.deny(id: "nope", reason: "x") }
        #expect(throws: ApprovalError.notFound) { try store.allowSimilar(id: "nope") }
    }

    @Test func denyRequiresNonEmptyReason() throws {
        let (store, _) = make()
        submitBash(store, id: "a", command: "rm -rf x")
        for reason in ["", " ", "   \t", "\n", " \n \t "] {
            #expect(throws: ApprovalError.emptyReason) { try store.deny(id: "a", reason: reason) }
        }
        // 失败的拒绝不改变状态
        #expect(store.pendingCount == 1)
        #expect(store.call(id: "a")?.status == .pending)
        let r = try store.deny(id: "a", reason: "  use trash instead \n")
        #expect(r.decision == .deny(reason: "use trash instead"))
        #expect(r.call.status == .denied)
        #expect(store.pendingCount == 0)
    }

    @Test func denyTwiceFails() throws {
        let (store, _) = make()
        submitBash(store, id: "a", command: "ls")
        try store.deny(id: "a", reason: "no")
        #expect(throws: ApprovalError.notPending) { try store.deny(id: "a", reason: "again") }
        #expect(throws: ApprovalError.notPending) { try store.allow(id: "a") }
    }

    @Test func duplicateRequestIDIsIgnored() {
        let (store, _) = make()
        submitBash(store, id: "a", command: "ls")
        #expect(submitBash(store, id: "a", command: "pwd") == .duplicate)
        #expect(store.pendingCount == 1)
    }

    @Test func historyIsBounded() throws {
        let store = ApprovalStore(clock: ApprovalTestClock(), historyLimit: 3)
        for i in 0..<10 {
            submitBash(store, id: "r\(i)", command: "echo \(i)")
            try store.allow(id: "r\(i)")
        }
        #expect(store.history.map(\.id) == ["r7", "r8", "r9"])
    }
}

@Suite struct ApprovalOrderingTests {
    @Test func riskDescendingThenWaitDescending() {
        let clock = ApprovalTestClock()
        let store = ApprovalStore(clock: clock)
        submitBash(store, id: "low1", command: "ls")
        clock.advance(1)
        submitBash(store, id: "med1", command: "my-tool --x")
        clock.advance(1)
        submitBash(store, id: "high1", command: "sudo ls")
        clock.advance(1)
        submitBash(store, id: "high2", command: "git push")
        clock.advance(1)
        submitBash(store, id: "med2", command: "other-tool")
        #expect(store.pending.map(\.id) == ["high1", "high2", "med1", "med2", "low1"])
        #expect(store.pending.map(\.risk) == [.high, .high, .medium, .medium, .low])
    }

    @Test func ties_keepArrivalOrder_whenTimestampsEqual() {
        let store = ApprovalStore(clock: ApprovalTestClock())
        let ids = (0..<30).map { "r\($0)" }
        for id in ids { submitBash(store, id: id, command: "rm -rf dir-\(id)") }
        #expect(store.pending.map(\.id) == ids)
        // 重复读取结果不变
        #expect(store.pending.map(\.id) == ids)
    }

    @Test func mixedTiesAreStablePerRiskClass() {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "m1", command: "foo-1")
        submitBash(store, id: "h1", command: "sudo a")
        submitBash(store, id: "m2", command: "foo-2")
        submitBash(store, id: "h2", command: "sudo b")
        submitBash(store, id: "l1", command: "ls a")
        submitBash(store, id: "m3", command: "foo-3")
        #expect(store.pending.map(\.id) == ["h1", "h2", "m1", "m2", "m3", "l1"])
    }

    @Test func removalKeepsRemainingOrder() throws {
        let store = ApprovalStore(clock: ApprovalTestClock())
        for i in 0..<5 { submitBash(store, id: "r\(i)", command: "sudo c\(i)") }
        try store.allow(id: "r2")
        #expect(store.pending.map(\.id) == ["r0", "r1", "r3", "r4"])
    }

    @Test func threeAgentsAtOnceBadgeCount() {
        let store = ApprovalStore(clock: ApprovalTestClock())
        for (i, agent) in [AgentKind.claude, .codex, .cursor].enumerated() {
            store.submit(
                requestID: "r\(i)", sessionID: "s\(i)", agent: agent, tool: "Bash",
                input: bashInput("rm -rf build"), cwd: "/p")
        }
        #expect(store.pendingCount == 3)
        #expect(store.pending.map(\.id) == ["r0", "r1", "r2"])
    }
}

@Suite struct ApprovalFoldingTests {
    @Test func repeatedCommandFoldsIntoOneRow() throws {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", command: "rm -rf build")
        let o2 = submitBash(store, id: "b", command: "rm  -rf   build")
        guard case .folded(let call) = o2 else { Issue.record("expected folded"); return }
        #expect(call.repeatCount == 2)
        #expect(call.id == "a")
        submitBash(store, id: "c", command: " rm -rf build ")
        #expect(store.pendingCount == 1)
        #expect(store.pending[0].repeatCount == 3)
        let r = try store.allow(id: "a")
        #expect(r.requestIDs == ["a", "b", "c"])
    }

    @Test func foldedRequestIDResolvesTheRow() throws {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", command: "ls x")
        submitBash(store, id: "b", command: "ls x")
        let r = try store.deny(id: "b", reason: "no")
        #expect(r.requestIDs == ["a", "b"])
        #expect(store.pendingCount == 0)
    }

    @Test func differentSessionToolOrCommandDoNotFold() {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", session: "s1", command: "rm -rf x")
        submitBash(store, id: "b", session: "s2", command: "rm -rf x")
        submitBash(store, id: "c", session: "s1", command: "rm -rf y")
        submitTool(store, id: "d", tool: "Shell", input: bashInput("rm -rf x"))
        #expect(store.pendingCount == 4)
    }

    @Test func whitespaceInsideQuotesDoesNotFold() {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", command: "echo 'a  b'")
        submitBash(store, id: "b", command: "echo 'a b'")
        #expect(store.pendingCount == 2)
    }

    @Test func nonShellToolsFoldOnIdenticalInput() {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitTool(store, id: "a", tool: "Edit", input: ["file_path": .string("a.ts")])
        submitTool(store, id: "b", tool: "Edit", input: ["file_path": .string("a.ts")])
        submitTool(store, id: "c", tool: "Edit", input: ["file_path": .string("b.ts")])
        #expect(store.pendingCount == 2)
        #expect(store.pending[0].repeatCount == 2)
    }

    @Test func resolvedRowDoesNotAbsorbLaterRequests() throws {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "a", command: "ls x")
        try store.allow(id: "a")
        guard case .queued = submitBash(store, id: "b", command: "ls x") else {
            Issue.record("expected a fresh row"); return
        }
        #expect(store.pendingCount == 1)
    }
}
