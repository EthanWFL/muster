import Foundation
import Testing
@testable import MusterCore

@Suite struct OwnershipHeuristicTests {
    let heuristic = OwnershipHeuristic()
    let session = CleanupFixture.session

    @Test func fullEvidenceIsConfident() {
        let process = CleanupFixture.record(200, ppid: 100, start: 10)
        let s = heuristic.score(process: process, commandLine: "node vite.js", session: session, tree: .currentTree)
        #expect(s.points == 100)
        #expect(s.confidence == 1.0)
        #expect(!s.isUncertain)
    }

    @Test func withoutTreeEvidenceIsAlwaysUncertain() {
        // 同 cwd、更晚启动、命令行含 node，但不在进程树内：最高 60 分
        let process = CleanupFixture.record(300, ppid: 1, start: 20, cwd: CleanupFixture.sessionCwd + "/sub")
        let s = heuristic.score(process: process, commandLine: "node server.js", session: session, tree: .none)
        #expect(s.points == 60)
        #expect(s.isUncertain)
        #expect(s.confidence < 0.8)
    }

    @Test func cwdMatchesByPathComponentNotStringPrefix() {
        let sibling = CleanupFixture.record(300, ppid: 1, start: 20, cwd: "/work/proj-other")
        let s = heuristic.score(process: sibling, commandLine: nil, session: session, tree: .none)
        #expect(!s.reasons.contains { $0.contains("cwd") })
    }

    @Test func processStartedBeforeSessionGetsNoStartPoints() {
        let early = CleanupFixture.record(300, ppid: 1, start: -500)
        let s = heuristic.score(process: early, commandLine: nil, session: session, tree: .none)
        #expect(!s.reasons.contains { $0.contains("启动时间") })
    }

    @Test func weightsAreAllInOneStruct() {
        let w = OwnershipWeights.default
        #expect(w.maxPoints == 100)
        #expect(w.confidentThreshold == 80)
    }

    @Test func rootDirectoryNeverMatchesAsCwdPrefix() {
        #expect(!OwnershipHeuristic.path("/anything", isInside: "/"))
    }

    @Test func bestOwnerPicksSessionWhoseTreeContainsProcess() {
        let records = CleanupFixture.defaultRecords()
        let snapshot = ProcessSnapshot(
            takenAt: CleanupFixture.t0.addingTimeInterval(100),
            processes: Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) }),
            commandLines: [200: "node vite.js"])
        let owner = heuristic.bestOwner(pid: 200, sessions: [session], snapshot: snapshot)
        #expect(owner?.sessionID == "s1")
        #expect(owner?.isUncertain == false)
        let stranger = heuristic.bestOwner(pid: 300, sessions: [session], snapshot: snapshot)
        #expect(stranger?.isUncertain == true)
    }

    @Test func reusedSessionRootPidDoesNotCountAsTree() {
        // session.pid=100 但现在的 100 号进程启动时间不同：PID 被复用，不承认其子树
        var records = CleanupFixture.defaultRecords()
        records[2] = CleanupFixture.record(100, ppid: 50, start: 9999, name: "other")
        let snapshot = ProcessSnapshot(
            takenAt: CleanupFixture.t0.addingTimeInterval(100),
            processes: Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) }))
        #expect(!snapshot.isInTree(of: session, pid: 200))
    }
}
