import Foundation
import Darwin

/// 把扫描结果合成 `CleanupPlan`。只读，不执行任何动作。
public struct CleanupPlanner: Sendable {
    public let heuristic: OwnershipHeuristic
    public let ownPID: Int32

    public init(heuristic: OwnershipHeuristic = OwnershipHeuristic(), ownPID: Int32 = getpid()) {
        self.heuristic = heuristic
        self.ownPID = ownPID
    }

    public func plan(
        sessions: [Session], snapshot: ProcessSnapshot, ports: [ListeningPort],
        orphans: [OrphanCandidate] = [], worktrees: [WorktreeInfo] = [], agentIDs: Set<String>? = nil
    ) -> CleanupPlan {
        if agentIDs?.isEmpty == true { return CleanupPlan(createdAt: snapshot.takenAt, items: []) }
        var items: [CleanupItem] = []
        var planned: Set<Int32> = []

        // 1. 监听端口：按 pid 合并
        let byPID = Dictionary(grouping: ports, by: \.pid)
        for pid in byPID.keys.sorted() {
            // A hidden Agent's actual process tree takes precedence over cwd/name scores,
            // including the case where two Agent kinds happen to use the same session id.
            if let agentIDs, sessions.contains(where: {
                !agentIDs.contains($0.agent.rawValue) && (snapshot.rootRecord(for: $0)?.pid == pid || snapshot.isInTree(of: $0, pid: pid))
            }) { continue }
            guard isCandidatePID(pid), let record = snapshot.processes[pid], let identity = record.identity,
                  let score = heuristic.bestOwner(pid: pid, sessions: sessions, snapshot: snapshot),
                  score.points >= heuristic.weights.displayFloor,
                  let session = sessions.first(where: { $0.id == score.sessionID }),
                  agentIDs?.contains(session.agent.rawValue) ?? true else { continue }
            let portNumbers = Array(Set(byPID[pid]!.map(\.port))).sorted()
            let target = ProcessTarget(
                identity: identity, name: record.name, commandLine: snapshot.commandLines[pid],
                kind: .listener, sessionID: session.id, ports: portNumbers, score: score,
                inSessionTreeAtPlan: snapshot.isInTree(of: session, pid: pid))
            items.append(CleanupItem(action: .terminate(target), title: Self.title(for: target)))
            planned.insert(pid)
        }

        // 2. 孤儿进程
        for orphan in orphans {
            let pid = orphan.identity.pid
            guard isCandidatePID(pid), !planned.contains(pid), let record = snapshot.processes[pid],
                  startTimesMatch(record.startTime, orphan.identity.startTime, tolerance: heuristic.weights.startTimeTolerance),
                  let score = heuristic.bestOwner(
                    pid: pid, sessions: sessions, snapshot: snapshot, formerlyOwnedBy: orphan.formerSessionID),
                  let session = sessions.first(where: { $0.id == orphan.formerSessionID }),
                  agentIDs?.contains(session.agent.rawValue) ?? true else { continue }
            let target = ProcessTarget(
                identity: orphan.identity, name: record.name, commandLine: snapshot.commandLines[pid],
                kind: .orphan, sessionID: session.id, ports: [], score: score,
                inSessionTreeAtPlan: snapshot.isInTree(of: session, pid: pid))
            items.append(CleanupItem(action: .terminate(target), title: Self.title(for: target)))
            planned.insert(pid)
        }

        // 3. 失效 worktree：每个仓库一条 prune；目录仍在的单独给删除项
        let stale = worktrees.filter(\.isStale)
        for repo in Array(Set(stale.map(\.repoRoot))).sorted() {
            let count = stale.filter { $0.repoRoot == repo }.count
            items.append(CleanupItem(
                action: .pruneWorktrees(repoRoot: repo),
                title: "清理 \((repo as NSString).lastPathComponent) 的失效 worktree 元数据 (\(count) 个)"))
        }
        for info in stale where !info.directoryMissing {
            items.append(CleanupItem(
                action: .removeWorktreeDirectory(repoRoot: info.repoRoot, path: info.path),
                title: "删除已合并 worktree 目录 \(info.path)"))
        }

        return CleanupPlan(createdAt: snapshot.takenAt, items: items)
    }

    private func isCandidatePID(_ pid: Int32) -> Bool {
        pid > 1 && pid != ownPID && pid != getpid()
    }

    private static func title(for target: ProcessTarget) -> String {
        let name = target.name ?? "进程"
        let suffix = target.score.isUncertain ? " (不确定)" : ""
        switch target.kind {
        case .listener:
            let ports = target.ports.map(String.init).joined(separator: ",")
            return "端口 \(ports) · \(name) (pid \(target.identity.pid))\(suffix)"
        case .orphan:
            return "孤儿进程 \(name) (pid \(target.identity.pid))\(suffix)"
        }
    }
}
