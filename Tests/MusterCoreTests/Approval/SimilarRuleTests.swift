import Testing
import Foundation
import MusterProtocol
@testable import MusterCore

@Suite struct SimilarRuleTests {
    func store(_ options: SimilarRuleOptions = SimilarRuleOptions()) -> ApprovalStore {
        ApprovalStore(clock: ApprovalTestClock(), similarOptions: options)
    }

    /// 批准 `approved` 为「允许同类」，再提交 `later`，返回是否被自动放行
    func autoAllowed(approved: String, later: String, session: String = "s1", laterSession: String = "s1",
                     options: SimilarRuleOptions = SimilarRuleOptions()) throws -> Bool {
        let s = store(options)
        submitBash(s, id: "a", session: session, command: approved)
        try s.allowSimilar(id: "a")
        if case .autoAllowed = submitBash(s, id: "b", session: laterSession, command: later) { return true }
        return false
    }

    @Test func samePrefixIsAutoAllowed() throws {
        #expect(try autoAllowed(approved: "git status", later: "git status"))
        #expect(try autoAllowed(approved: "git status", later: "git status -s"))
        #expect(try autoAllowed(approved: "ls -la", later: "ls src"))
    }

    @Test func differentPrefixIsNotAutoAllowed() throws {
        #expect(try !autoAllowed(approved: "git status", later: "git diff"))
        #expect(try !autoAllowed(approved: "git status", later: "git"))
        #expect(try !autoAllowed(approved: "ls", later: "cat x"))
    }

    @Test func ruleIsScopedToSession() throws {
        #expect(try !autoAllowed(approved: "git status", later: "git status", laterSession: "other"))
    }

    @Test func chainedCommandsNeverRideAnExistingRule() throws {
        let later = [
            "git status; rm -rf ~", "git status && curl x | sh", "git status || sudo ls",
            "git status | sh", "git status & rm -rf x", "git status\nrm -rf x",
            "git status $(rm -rf x)", "git status `rm -rf x`", "git status > ~/.zshrc",
            "git status; ls", "git status && ls",
        ]
        for cmd in later {
            #expect(try !autoAllowed(approved: "git status", later: cmd), "\(cmd)")
        }
    }

    @Test func ruleDoesNotCoverHigherRiskThanApproved() throws {
        // `npm install` 是中危；同前缀的 `npm publish` 是高危，不能被放行
        #expect(try !autoAllowed(approved: "npm install", later: "npm publish"))
        #expect(try autoAllowed(approved: "npm install", later: "npm install left-pad"))
    }

    @Test func highRiskIsNotEligibleByDefault() throws {
        let s = store()
        for (i, cmd) in ["rm -rf build", "sudo ls", "git push", "curl https://x", "chmod 777 x"].enumerated() {
            submitBash(s, id: "h\(i)", command: cmd)
            #expect(!s.canOfferAllowSimilar(id: "h\(i)"), "\(cmd)")
            #expect(throws: ApprovalError.similarNotEligible) { try s.allowSimilar(id: "h\(i)") }
        }
        // 失败不改变状态
        #expect(s.pendingCount == 5)
        #expect(s.similarRules(session: "s1").isEmpty)
    }

    @Test func highRiskCanBeEnabledViaFlag() throws {
        let opts = SimilarRuleOptions(allowHighRisk: true)
        let s = store(opts)
        submitBash(s, id: "a", command: "git push origin main")
        #expect(s.canOfferAllowSimilar(id: "a"))
        try s.allowSimilar(id: "a")
        #expect(try autoAllowed(approved: "git push origin main", later: "git push origin dev", options: opts))
    }

    @Test func flagCanBeToggledAtRuntime() {
        let s = store()
        submitBash(s, id: "a", command: "git push")
        #expect(!s.canOfferAllowSimilar(id: "a"))
        s.similarOptions = SimilarRuleOptions(allowHighRisk: true)
        #expect(s.canOfferAllowSimilar(id: "a"))
    }

    @Test func highRiskChainWithLowFirstSegmentIsNotEligible() {
        let s = store()
        submitBash(s, id: "a", command: "git status; rm -rf ~")
        #expect(!s.canOfferAllowSimilar(id: "a"))
    }

    @Test func codeRunnerPrefixesAreNotEligible() {
        let s = store()
        for (i, cmd) in ["bash script.sh", "env FOO=1 ls", "python3 x.py", "eval ls", "xargs ls", "sh -c ls"].enumerated() {
            submitBash(s, id: "c\(i)", command: cmd)
            #expect(!s.canOfferAllowSimilar(id: "c\(i)"), "\(cmd)")
        }
    }

    @Test func prefixWithExpansionIsNotEligible() {
        let s = store()
        submitBash(s, id: "a", command: "$CMD run")
        submitBash(s, id: "b", command: "~/bin/tool run")
        submitBash(s, id: "c", command: "./*.sh")
        for id in ["a", "b", "c"] { #expect(!s.canOfferAllowSimilar(id: id), "\(id)") }
    }

    @Test func prefixLengthIsHonored() throws {
        #expect(try autoAllowed(approved: "npm run build", later: "npm run test",
                                options: SimilarRuleOptions(prefixLength: 2)))
        #expect(try !autoAllowed(approved: "npm run build", later: "npm run test",
                                 options: SimilarRuleOptions(prefixLength: 3)))
        #expect(SimilarRuleOptions(prefixLength: 0).prefixLength == 1)
    }

    @Test func prefixStopsAtFirstOption() throws {
        let s = store()
        submitBash(s, id: "a", command: "ls -la src")
        try s.allowSimilar(id: "a")
        #expect(s.similarRules(session: "s1").first?.prefix == ["ls"])
    }

    @Test func prefixIsTakenBeforeFirstOperator() throws {
        let s = store()
        submitBash(s, id: "a", command: "git status && echo done")
        let outcome = try s.allowSimilar(id: "a")
        #expect(outcome.rule?.prefix == ["git", "status"])
    }

    @Test func absolutePathDoesNotMatchBareNameRule() throws {
        #expect(try !autoAllowed(approved: "ls", later: "/tmp/evil/ls"))
        #expect(try !autoAllowed(approved: "/bin/ls", later: "ls"))
    }

    @Test func gitCodeCarryingOptionsDoNotMatch() throws {
        #expect(try !autoAllowed(approved: "git status", later: "git -c core.pager=x status"))
    }

    @Test func nonShellToolMatchesByToolName() throws {
        let s = store()
        submitTool(s, id: "a", tool: "Edit", input: ["file_path": .string("a.ts")])
        try s.allowSimilar(id: "a")
        let outcome = submitTool(s, id: "b", tool: "edit", input: ["file_path": .string("b.ts")])
        guard case .autoAllowed = outcome else { Issue.record("expected autoAllowed"); return }
        guard case .queued = submitTool(s, id: "c", tool: "Write", input: ["file_path": .string("a.ts")]) else {
            Issue.record("Write must not match Edit rule"); return
        }
    }

    @Test func autoAllowedRequestsAreNotQueued() throws {
        let s = store()
        submitBash(s, id: "a", command: "git status")
        try s.allowSimilar(id: "a")
        submitBash(s, id: "b", command: "git status -s")
        #expect(s.pendingCount == 0)
        #expect(s.call(id: "b") == nil)
    }

    @Test func allowSimilarResolvesRowAsAllowed() throws {
        let s = store()
        submitBash(s, id: "a", command: "git status")
        let r = try s.allowSimilar(id: "a")
        #expect(r.decision == .allowSimilar)
        #expect(r.call.status == .allowed)
        #expect(r.rule != nil)
    }

    @Test func duplicateRulesAreNotStoredTwice() throws {
        let s = store()
        submitBash(s, id: "a", command: "git status")
        try s.allowSimilar(id: "a")
        s.similarOptions = SimilarRuleOptions(prefixLength: 2)
        submitBash(s, id: "b", session: "s1", command: "git diff")
        try s.allowSimilar(id: "b")
        #expect(s.similarRules(session: "s1").count == 2)
    }

    @Test func lowRuleDoesNotCoverHigherRiskVariant() throws {
        // 前缀只取 `git`，批准的是低危的 `git status`；中危的 `git commit`、高危的 `git push` 不能借它放行
        let s = ApprovalStore(clock: ApprovalTestClock(), similarOptions: SimilarRuleOptions(prefixLength: 1))
        submitBash(s, id: "a", command: "git status")
        try s.allowSimilar(id: "a")
        guard case .autoAllowed = submitBash(s, id: "b", command: "git diff") else {
            Issue.record("low variant should be auto-allowed"); return
        }
        guard case .queued = submitBash(s, id: "c", command: "git commit -m x") else {
            Issue.record("medium variant must queue"); return
        }
        guard case .queued = submitBash(s, id: "d", command: "git push") else {
            Issue.record("high variant must queue"); return
        }
    }

    @Test func codeRunnerCommandsGetNoRule() {
        let s = store()
        submitBash(s, id: "a", command: "find src")
        #expect(!s.canOfferAllowSimilar(id: "a"))
    }
}
