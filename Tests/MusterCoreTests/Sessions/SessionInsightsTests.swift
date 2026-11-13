import Foundation
import Testing
@testable import MusterCore

@Suite struct SessionInsightsTests {
    private func session(_ id: String, _ state: SessionState, agent: AgentKind = .claude, cwd: String = "/tmp/a b") -> Session {
        Session(id: id, agent: agent, cwd: cwd, startedAt: Date(), state: state)
    }

    @Test func branchFromHeadAndWorktreePointer() throws {
        let tree = try TempTree()
        try tree.write("repo/.git/HEAD", "ref: refs/heads/feat/x\n")
        #expect(SessionInsights.branch(cwd: tree.path("repo")) == "feat/x")

        try tree.write("main/.git/worktrees/wt/HEAD", "0123456789abcdef\n")
        try tree.write("wt/.git", "gitdir: \(tree.path("main/.git/worktrees/wt"))\n")
        #expect(SessionInsights.branch(cwd: tree.path("wt")) == "0123456")

        #expect(SessionInsights.branch(cwd: tree.path("none")) == nil)
    }

    @Test func finishedOnlyWhenRunningBecomesIdle() {
        let before = [session("a", .running), session("b", .idle), session("c", .running), session("d", .running)]
        let after = [session("a", .idle), session("b", .idle), session("c", .running)]
        #expect(SessionInsights.finished(from: before, to: after).map(\.id) == ["a"])
    }

    @Test func resumeCommandQuotesPathAndRejectsUnknown() {
        #expect(session("abc-1", .idle).resumeCommand == "cd '/tmp/a b' && claude --resume abc-1")
        #expect(session("abc-1", .idle, agent: .codex, cwd: "/x").resumeCommand == "cd /x && codex resume abc-1")
        #expect(session("proc-42", .running).resumeCommand == nil)
        #expect(session("a;rm -rf", .idle).resumeCommand == nil)
        #expect(session("abc", .idle, agent: .gemini).resumeCommand == nil)
    }
}

@Suite struct ProtectedFoldersTests {
    @Test func flagsOnlyTheFoldersThatPrompt() {
        let home = "/Users/me"
        #expect(ProtectedFolders.contains("/Users/me/Documents", home: home))
        #expect(ProtectedFolders.contains("/Users/me/Documents/a/b", home: home))
        #expect(ProtectedFolders.contains("/Users/me/Desktop/../Downloads/x", home: home))
        #expect(ProtectedFolders.contains("/Volumes/usb/repo", home: home))
        #expect(!ProtectedFolders.contains("/Users/me/Code/Documents", home: home))
        #expect(!ProtectedFolders.contains("/Users/me/DocumentsOld", home: home))
        #expect(!ProtectedFolders.contains("/Users/me/.pachat/codex-workspace", home: home))
    }

    @Test func branchLookupSkipsProtectedCwd() throws {
        #expect(SessionInsights.branch(cwd: NSHomeDirectory() + "/Documents/anything") == nil)
    }
}
