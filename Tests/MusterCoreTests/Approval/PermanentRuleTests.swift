import Foundation
import Testing
import MusterProtocol
@testable import MusterCore

@Suite struct PermanentRuleTests {
    @Test func parsesOnlyExactBashRules() {
        #expect(PermanentRule.parse("Bash(git status)")?.command == "git status")
        #expect(PermanentRule.parse("  Bash(ls -la)  ")?.text == "Bash(ls -la)")
        #expect(PermanentRule.parse("Bash(git:*)") == nil)
        #expect(PermanentRule.parse("Bash(*)") == nil)
        #expect(PermanentRule.parse("Read(/tmp/x)") == nil)
        #expect(PermanentRule.parse("Bash(ls") == nil)
    }

    @Test func rejectsCommandsThatAreNotExact() {
        let bad = [
            "", "   ", "git *", "ls; rm -rf ~", "ls && rm", "ls || rm", "ls | sh",
            "echo $(whoami)", "echo `id`", "echo $HOME", "echo x > y", "ls\nrm",
        ]
        for command in bad {
            #expect(PermanentRule.make(command: command) == nil, "\(command)")
        }
        #expect(PermanentRule.make(command: "  touch out.txt " )?.text == "Bash(touch out.txt)")
    }

    @Test func matchesOnlyIdenticalTrimmedCommand() throws {
        let rule = try #require(PermanentRule.make(command: "touch out.txt"))
        #expect(rule.matches(tool: "Bash", input: bashInput("touch out.txt")))
        #expect(rule.matches(tool: "bash", input: bashInput(" touch out.txt\n")))
        #expect(!rule.matches(tool: "Bash", input: bashInput("touch out.txt; rm -rf ~")))
        #expect(!rule.matches(tool: "Bash", input: bashInput("touch other.txt")))
        #expect(!rule.matches(tool: "Read", input: bashInput("touch out.txt")))
    }

    @Test func storeAutoAllowsPermanentlyAcrossSessions() throws {
        let store = ApprovalStore(clock: ApprovalTestClock())
        store.replacePermanentRules([PermanentRule(tool: "bash", command: "touch out.txt")])

        guard case .autoAllowedPermanently(let rule) = submitBash(store, id: "a", session: "s1", command: "touch out.txt") else {
            Issue.record("expected a permanent auto-allow")
            return
        }
        #expect(rule.text == "Bash(touch out.txt)")
        guard case .autoAllowedPermanently = submitBash(store, id: "b", session: "other", command: "touch out.txt") else {
            Issue.record("permanent rules must not be session-scoped")
            return
        }
        guard case .queued = submitBash(store, id: "c", command: "touch out.txt.bak") else {
            Issue.record("a near match must still queue")
            return
        }
        #expect(store.pendingCount == 1)
    }

    @Test func snippetOnlyOffersEligibleRulesThatAreNotAlreadySaved() throws {
        let store = ApprovalStore(clock: ApprovalTestClock())
        submitBash(store, id: "simple", command: "rm -rf build")
        #expect(store.permanentRuleSnippet(id: "simple") == "Bash(rm -rf build)")

        submitBash(store, id: "compound", command: "git status; rm -rf ~")
        #expect(store.permanentRuleSnippet(id: "compound") == nil)

        submitTool(store, id: "read", tool: "Read", input: ["file_path": .string("/tmp/x")])
        #expect(store.permanentRuleSnippet(id: "read") == nil)

        store.replacePermanentRules([PermanentRule(tool: "bash", command: "rm -rf build")])
        #expect(store.permanentRuleSnippet(id: "simple") == nil)
        #expect(store.currentPermanentRules.count == 1)
        #expect(store.permanentRuleSnippet(id: "missing") == nil)
    }
}

@Suite struct PermanentAllowDaemonTests {
    @Test func permanentAllowRespondsImmediatelyAndRecordsAgentPID() async throws {
        let store = ApprovalStore(clock: ApprovalTestClock())
        store.replacePermanentRules([PermanentRule(tool: "bash", command: "ls")])
        let daemon = AgentDaemon(approvals: store, sessions: SessionStore(), log: { _ in })
        let request = WireRequest(
            id: "p1", session: "s1", agent: "claude", tool: "Bash",
            input: bashInput("ls"), cwd: "/tmp/proj", ts: 1,
            pid: 4242, pidStartedAt: 1_700_000_000)

        let response = await daemon.handle(request)
        #expect(response.decision == .allow)
        #expect(response.reason?.contains("Bash(ls)") == true)
        #expect(store.pendingCount == 0)

        let session = try #require(daemon.sessions.session(id: "s1"))
        #expect(session.pid == 4242)
        #expect(session.pidStartTime == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
