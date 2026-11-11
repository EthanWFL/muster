import Foundation
import Testing
@testable import MusterCore

/// 真实 git + 系统临时目录。测试结束必删。
final class TempGitRepo {
    let root: URL
    let main: String
    let runner = CleanupCommandRunner()

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("muster-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // 用 realpath 而不是 resolvingSymlinksInPath：后者会把 /private/var 改写成 /var，
        // 而 git 报告的是 /private/var，路径比较会对不上
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(base.path, &buffer) != nil ? String(cString: buffer) : base.path
        root = URL(fileURLWithPath: resolved)
        main = root.appendingPathComponent("main").path
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], cwd: main)
        try commit("init", cwd: main)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func git(_ args: [String], cwd: String) throws -> String {
        let base = ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
        let result = try runner.run(base + args, cwd: cwd)
        guard result.status == 0 else {
            throw NSError(domain: "git", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }
        return result.stdout
    }

    func commit(_ message: String, cwd: String) throws {
        try git(["commit", "-q", "--allow-empty", "-m", message], cwd: cwd)
    }

    func addWorktree(_ name: String, branch: String) throws -> String {
        let path = root.appendingPathComponent(name).path
        try git(["worktree", "add", "-q", "-b", branch, path], cwd: main)
        return path
    }
}

@Suite struct WorktreeScannerTests {
    @Test func parsesPorcelain() {
        let text = """
        worktree /r/main
        HEAD abc
        branch refs/heads/main

        worktree /r/wt
        HEAD def
        branch refs/heads/feat
        locked

        worktree /r/det
        HEAD 123
        detached
        """
        let list = WorktreeScanner.parsePorcelain(text)
        #expect(list.count == 3)
        #expect(list[1].branch == "feat")
        #expect(list[1].isLocked)
        #expect(list[2].branch == nil)
    }

    @Test func missingDirectoriesAreStaleAndPruneFixesThem() throws {
        let repo = try TempGitRepo()
        let a = try repo.addWorktree("a", branch: "fa")
        let b = try repo.addWorktree("b", branch: "fb")
        let c = try repo.addWorktree("c", branch: "fc")
        try FileManager.default.removeItem(atPath: a)
        try FileManager.default.removeItem(atPath: b)

        let scanner = WorktreeScanner(runner: repo.runner)
        let before = try scanner.scan(repoAt: repo.main)
        #expect(before.count == 4)
        #expect(before.filter(\.isStale).count == 2)
        #expect(before.first { $0.path == c }?.isStale == false)
        #expect(before.first?.isMain == true)

        let plan = CleanupPlanner().plan(
            sessions: [], snapshot: ProcessSnapshot(takenAt: Date(), processes: [:]), ports: [], worktrees: before)
        #expect(plan.items.count == 1)
        #expect(plan.items[0].command.argv == ["git", "worktree", "prune"])
        #expect(!plan.items[0].needsExplicitConfirmation)

        let executor = CleanupExecutor(
            runner: repo.runner, signaller: CleanupRecordingSignaller(), log: CleanupMemoryLog())
        let report = executor.execute(
            plan: plan, request: CleanupRequest(selected: plan.preselectedIDs), sessions: [])
        #expect(report.prunedRepositories == [repo.main])
        #expect(report.refusedCount == 0 && report.failedCount == 0)

        let after = try scanner.scan(repoAt: repo.main)
        #expect(after.count == 2)
        #expect(after.allSatisfy { !$0.isStale })
        #expect(FileManager.default.fileExists(atPath: c))
    }

    @Test func mergedBranchIsDetectedAndFreshEmptyBranchIsNot() throws {
        let repo = try TempGitRepo()
        let done = try repo.addWorktree("done", branch: "done-branch")
        try repo.commit("work", cwd: done)
        try repo.git(["merge", "-q", "--no-ff", "-m", "merge", "done-branch"], cwd: repo.main)
        // 合并之后才建：此时分支头 == 主分支头，属于「刚建的空分支」，不能算已合并
        let fresh = try repo.addWorktree("fresh", branch: "fresh-branch")

        let list = try WorktreeScanner(runner: repo.runner).scan(repoAt: repo.main)
        #expect(list.first { $0.path == done }?.branchMerged == true)
        #expect(list.first { $0.path == fresh }?.branchMerged == false)
    }

    @Test func pruneDoesNotDeleteExistingDirectories() throws {
        let repo = try TempGitRepo()
        let merged = try repo.addWorktree("merged", branch: "m")
        try repo.commit("work", cwd: merged)
        try repo.git(["merge", "-q", "--no-ff", "-m", "merge", "m"], cwd: repo.main)

        let scanner = WorktreeScanner(runner: repo.runner)
        let list = try scanner.scan(repoAt: repo.main)
        let plan = CleanupPlanner().plan(
            sessions: [], snapshot: ProcessSnapshot(takenAt: Date(), processes: [:]), ports: [], worktrees: list)
        let executor = CleanupExecutor(
            runner: repo.runner, signaller: CleanupRecordingSignaller(), log: CleanupMemoryLog())

        // 只执行默认动作（prune）
        let prune = plan.items.filter { if case .pruneWorktrees = $0.action { return true } else { return false } }
        _ = executor.execute(plan: plan, request: CleanupRequest(selected: Set(prune.map(\.id))), sessions: [])
        #expect(FileManager.default.fileExists(atPath: merged))
    }

    @Test func directoryRemovalNeedsExplicitConfirmation() throws {
        let repo = try TempGitRepo()
        let merged = try repo.addWorktree("merged", branch: "m")
        try repo.commit("work", cwd: merged)
        try repo.git(["merge", "-q", "--no-ff", "-m", "merge", "m"], cwd: repo.main)

        let list = try WorktreeScanner(runner: repo.runner).scan(repoAt: repo.main)
        let plan = CleanupPlanner().plan(
            sessions: [], snapshot: ProcessSnapshot(takenAt: Date(), processes: [:]), ports: [], worktrees: list)
        let removal = try #require(plan.items.first {
            if case .removeWorktreeDirectory = $0.action { return true } else { return false }
        })
        #expect(removal.needsExplicitConfirmation)
        #expect(!plan.preselectedIDs.contains(removal.id))

        let executor = CleanupExecutor(
            runner: repo.runner, signaller: CleanupRecordingSignaller(), log: CleanupMemoryLog())

        let refused = executor.execute(
            plan: plan, request: CleanupRequest(selected: [removal.id]), sessions: [])
        #expect(refused.entries.first?.outcome == .refused(.confirmationRequired))
        #expect(FileManager.default.fileExists(atPath: merged))

        let confirmed = executor.execute(
            plan: plan, request: CleanupRequest(selected: [removal.id], confirmed: [removal.id]), sessions: [])
        #expect(confirmed.entries.first?.outcome == .done)
        #expect(confirmed.removedDirectories == [merged])
        #expect(!FileManager.default.fileExists(atPath: merged))
    }

    @Test func removalOfUnregisteredOrMainDirectoryIsRefused() throws {
        let repo = try TempGitRepo()
        let executor = CleanupExecutor(
            runner: repo.runner, signaller: CleanupRecordingSignaller(), log: CleanupMemoryLog())

        for path in [repo.main, repo.root.path, NSHomeDirectory()] {
            let item = CleanupItem(
                action: .removeWorktreeDirectory(repoRoot: repo.main, path: path), title: "x")
            let plan = CleanupPlan(createdAt: Date(), items: [item])
            let report = executor.execute(
                plan: plan, request: CleanupRequest(selected: [item.id], confirmed: [item.id]), sessions: [])
            #expect(report.entries.first?.outcome == .refused(.unsafePath))
        }
        #expect(FileManager.default.fileExists(atPath: repo.main))
    }
}
