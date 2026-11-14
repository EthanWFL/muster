import Foundation
import Testing
@testable import MusterCore

@Suite struct AgentScopeCleanupTests {
    @Test func disabledAgentsStayInOwnershipContextButNeverBecomeCleanupTargets() {
        let now = Date()
        let claude = Session(id: "claude", agent: .claude, cwd: "/work/shared", pid: 111, startedAt: now)
        let codex = Session(id: "codex", agent: .codex, cwd: "/work/shared", pid: 222, startedAt: now)
        let records = [
            ProcessRecord(pid: 111, ppid: 1, startTime: now, cwd: "/work/shared"),
            ProcessRecord(pid: 222, ppid: 1, startTime: now, cwd: "/work/shared"),
            ProcessRecord(pid: 333, ppid: 222, startTime: now, cwd: "/work/shared", name: "node")
        ]
        let snapshot = ProcessSnapshot(takenAt: now, processes: Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) }))
        let ports = [ListeningPort(pid: 333, command: "node", port: 3000, address: "127.0.0.1")]
        let planner = CleanupPlanner(ownPID: 9999)
        #expect(planner.plan(sessions: [claude, codex], snapshot: snapshot, ports: ports).items.count == 1)
        #expect(planner.plan(sessions: [claude, codex], snapshot: snapshot, ports: ports, agentIDs: ["claude"]).items.isEmpty)
        let collidingID = Session(id: claude.id, agent: .codex, cwd: "/work/shared", pid: 222, startedAt: now)
        #expect(planner.plan(sessions: [claude, collidingID], snapshot: snapshot, ports: ports, agentIDs: ["claude"]).items.isEmpty)
    }

    @Test func scopeChangePurgesDisabledOrphansAndRejectsOldScanResults() {
        let now = Date()
        let claude = Session(id: "claude", agent: .claude, cwd: "/a", pid: 111, startedAt: now)
        let codex = Session(id: "codex", agent: .codex, cwd: "/b", pid: 222, startedAt: now)
        let records = [
            ProcessRecord(pid: 111, ppid: 1, startTime: now), ProcessRecord(pid: 112, ppid: 111, startTime: now),
            ProcessRecord(pid: 222, ppid: 1, startTime: now), ProcessRecord(pid: 223, ppid: 222, startTime: now)
        ]
        let snapshot = ProcessSnapshot(takenAt: now, processes: Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) }))
        let detector = OrphanDetector()
        detector.observe(snapshot: snapshot, sessions: [claude, codex])
        #expect(detector.trackedCount == 2)
        detector.restrictToAgents(["claude"])
        #expect(detector.trackedCount == 1)
        detector.observe(snapshot: snapshot, sessions: [claude, codex])
        #expect(detector.trackedCount == 1)
        detector.restrictToAgents([])
        #expect(!detector.needsSampling(sessions: [claude, codex]))
        #expect(detector.trackedCount == 0)
    }
}
