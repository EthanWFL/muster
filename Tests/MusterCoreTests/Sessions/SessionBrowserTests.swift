import Foundation
import Testing
@testable import MusterCore

@Suite struct SessionBrowserTests {
    func session(_ id: String, agent: AgentKind = .claude, cwd: String = "/work/app",
                 state: SessionState = .running, activity: TimeInterval = 0, branch: String? = nil) -> Session {
        var result = Session(id: id, agent: agent, cwd: cwd, startedAt: Date(timeIntervalSince1970: 0),
                             lastActivityAt: Date(timeIntervalSince1970: activity), state: state)
        result.branch = branch
        return result
    }

    @Test func searchCombinesTermsAcrossAgentPathAndBranch() {
        let sessions = [session("a", agent: .codex, branch: "feature/Café"),
                        session("b", agent: .claude, branch: "feature/Café")]
        let groups = SessionBrowser(query: "  CODEX cafe app\n").groups(in: sessions)
        #expect(groups.flatMap(\.sessions).map(\.id) == ["a"])
    }

    @Test func filteringAndSearchComposeAndNeverShowEndedSessions() {
        let sessions = [session("a"), session("b", state: .idle), session("c", state: .unknown), session("d", state: .ended)]
        #expect(SessionBrowser(activity: .all).groups(in: sessions).flatMap(\.sessions).count == 3)
        #expect(SessionBrowser(activity: .quiet).groups(in: sessions).flatMap(\.sessions).map(\.id) == ["b"])
        #expect(SessionBrowser(query: "missing", activity: .quiet).groups(in: sessions).isEmpty)
        #expect(SessionBrowser(activity: .unknown).groups(in: sessions).flatMap(\.sessions).map(\.id) == ["c"])
    }

    @Test func projectGroupsCombineAgentsButDoNotMergeSameFolderNames() {
        let sessions = [session("a"), session("b", agent: .codex, cwd: "/work/./app/"),
                        session("c", cwd: "/other/app"), session("d", cwd: ""), session("e", cwd: "")]
        let groups = SessionBrowser(grouping: .project).groups(in: sessions)
        #expect(groups.count == 4)
        #expect(groups.first { $0.projectPath == "/work/app" }?.sessions.count == 2)
        #expect(groups.filter { $0.projectPath == nil }.count == 2)
    }

    @Test func orderIsStableAndNewestActivityComesFirst() {
        let sessions = [session("b", activity: 10), session("a", activity: 10), session("c", activity: 20)]
        let browser = SessionBrowser()
        #expect(browser.groups(in: sessions).flatMap(\.sessions).map(\.id) == ["c", "a", "b"])
        #expect(browser.groups(in: sessions.reversed()).flatMap(\.sessions).map(\.id) == ["c", "a", "b"])
    }
}
