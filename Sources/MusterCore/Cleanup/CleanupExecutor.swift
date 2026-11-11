import Foundation
import Darwin

/// 用户在界面上的选择。`confirmed` 是逐项的显式二次确认，与 `selected` 分开。
public struct CleanupRequest: Equatable, Sendable {
    public var selected: Set<String>
    public var confirmed: Set<String>

    public init(selected: Set<String>, confirmed: Set<String> = []) {
        self.selected = selected
        self.confirmed = confirmed
    }
}

/// 执行层。R6 的全部校验都在这里，不依赖 UI 是否做过检查。
public final class CleanupExecutor: @unchecked Sendable {
    public static let killGracePeriod: TimeInterval = 10

    private let table: ProcessTable
    private let runner: CommandRunner
    private let signaller: ProcessSignaller
    private let clock: Clock
    private let log: CleanupLog
    private let fileSystem: CleanupFileSystem
    private let heuristic: OwnershipHeuristic
    private let ownPID: Int32

    private let lock = NSLock()
    private var termSentAt: [ProcessIdentity: Date] = [:]

    public init(
        table: ProcessTable = LibprocProcessTable(), runner: CommandRunner,
        signaller: ProcessSignaller = SystemProcessSignaller(), clock: Clock = SystemClock(),
        log: CleanupLog, fileSystem: CleanupFileSystem = SystemCleanupFileSystem(),
        heuristic: OwnershipHeuristic = OwnershipHeuristic(), ownPID: Int32 = getpid()
    ) {
        self.table = table
        self.runner = runner
        self.signaller = signaller
        self.clock = clock
        self.log = log
        self.fileSystem = fileSystem
        self.heuristic = heuristic
        self.ownPID = ownPID
    }

    // MARK: - 执行计划

    public func execute(plan: CleanupPlan, request: CleanupRequest, sessions: [Session]) -> CleanupReport {
        var report = CleanupReport()
        for item in plan.items where request.selected.contains(item.id) {
            let confirmed = request.confirmed.contains(item.id)
            let outcome: CleanupOutcome
            switch item.action {
            case .terminate(let target):
                outcome = terminate(target, command: item.command, confirmed: confirmed, sessions: sessions)
                if outcome == .termSent {
                    report.awaitingExit.append(target)
                }
            case .pruneWorktrees(let repoRoot):
                outcome = prune(item.command, repoRoot: repoRoot)
                if outcome == .done { report.prunedRepositories.append(repoRoot) }
            case .removeWorktreeDirectory(let repoRoot, let path):
                var freed: Int64 = 0
                outcome = removeDirectory(item.command, repoRoot: repoRoot, path: path, confirmed: confirmed, freed: &freed)
                if outcome == .done {
                    report.removedDirectories.append(path)
                    report.reclaimedBytes += freed
                }
            }
            report.entries.append(CleanupEntry(
                itemID: item.id, title: item.title, commandText: item.command.displayText, outcome: outcome))
        }
        return report
    }

    /// SIGTERM 之后进程可能还没退出。调用此方法把已退出的进程的端口计入「释放端口」。
    public func reconcile(_ report: inout CleanupReport) {
        var stillWaiting: [ProcessTarget] = []
        for target in report.awaitingExit {
            if isSameProcessAlive(target.identity) {
                stillWaiting.append(target)
            } else {
                report.freedPorts.append(contentsOf: target.ports)
            }
        }
        report.awaitingExit = stillWaiting
        report.freedPorts = Array(Set(report.freedPorts)).sorted()
    }

    // MARK: - SIGKILL（独立的、需要显式调用的升级动作）

    /// 只有此前由本执行器发过 SIGTERM、已过 10 秒且进程仍是同一个时才会发 SIGKILL。
    /// `userConfirmed` 必须是用户针对 SIGKILL 的单独点击，不能复用 SIGTERM 的确认。
    public func forceKill(_ target: ProcessTarget, userConfirmed: Bool) -> CleanupOutcome {
        let identity = target.identity
        let label = "SIGKILL pid=\(identity.pid)"
        if let refusal = basicRefusal(identity) { return refuse(label, refusal) }
        guard userConfirmed else { return refuse(label, .confirmationRequired) }

        lock.lock()
        let sentAt = termSentAt[identity]
        lock.unlock()
        guard let sentAt else { return refuse(label, .notTerminatedByUs) }
        guard clock.now().timeIntervalSince(sentAt) >= Self.killGracePeriod else {
            return refuse(label, .gracePeriodNotElapsed)
        }
        guard let live = table.record(for: identity.pid) else { return refuse(label, .processGone) }
        guard startTimesMatch(live.startTime, identity.startTime, tolerance: heuristic.weights.startTimeTolerance) else {
            return refuse(label, .identityChanged)
        }
        return send(.kill, to: identity, label: label)
    }

    // MARK: - 内部：kill

    private func terminate(
        _ target: ProcessTarget, command: PlannedCommand, confirmed: Bool, sessions: [Session]
    ) -> CleanupOutcome {
        let identity = target.identity
        let label = "SIGTERM pid=\(identity.pid) (\(target.name ?? "?"))"

        // 1. pid > 1、不是自身
        if let refusal = basicRefusal(identity) { return refuse(label, refusal) }

        // 2. 仍是规划时的同一个进程
        guard let live = table.record(for: identity.pid) else { return refuse(label, .processGone) }
        guard startTimesMatch(live.startTime, identity.startTime, tolerance: heuristic.weights.startTimeTolerance) else {
            return refuse(label, .identityChanged)
        }

        // 3. 在 session 进程树内，或已二次确认。进程树用实时进程表重新计算
        let session = sessions.first { $0.id == target.sessionID }
        var inTree = false
        if let session {
            inTree = liveSnapshot().isInTree(of: session, pid: identity.pid)
        }
        if !inTree && !confirmed { return refuse(label, .notInSessionTree) }

        // 4. 置信度：规划时或此刻任一偏低都视为不确定，需要二次确认
        var uncertain = target.score.isUncertain
        if let session {
            let evidence: TreeEvidence = inTree ? .currentTree : (target.kind == .orphan ? .formerTree : .none)
            let liveScore = heuristic.score(
                process: live, commandLine: target.commandLine, session: session, tree: evidence)
            uncertain = uncertain || liveScore.isUncertain
        } else {
            uncertain = true
        }
        if uncertain && !confirmed { return refuse(label, .uncertainOwnership) }

        // 5. 展示的命令必须就是 SIGTERM + 这个 pid；不一致说明计划对象被篡改
        guard command.argv == ["kill", CleanupSignal.term.flag, String(identity.pid)] else {
            return refuse(label, .confirmationRequired)
        }

        let outcome = send(.term, to: identity, label: label)
        if outcome == .termSent {
            lock.lock()
            termSentAt[identity] = clock.now()
            lock.unlock()
        }
        return outcome
    }

    /// pid <= 1、本 app 自身。每次发信号前都要过。
    private func basicRefusal(_ identity: ProcessIdentity) -> CleanupRefusal? {
        if identity.pid <= 1 { return .invalidPID(identity.pid) }
        if identity.pid == ownPID || identity.pid == getpid() { return .ownProcess }
        return nil
    }

    private func send(_ signal: CleanupSignal, to identity: ProcessIdentity, label: String) -> CleanupOutcome {
        do {
            try signaller.send(signal, to: identity.pid)
            log.log("cleanup: \(label) sent")
            return signal == .term ? .termSent : .done
        } catch {
            log.log("cleanup: \(label) failed: \(error)")
            return .failed("\(error)")
        }
    }

    private func refuse(_ label: String, _ reason: CleanupRefusal) -> CleanupOutcome {
        log.log("cleanup: REFUSED \(label): \(reason)")
        return .refused(reason)
    }

    private func isSameProcessAlive(_ identity: ProcessIdentity) -> Bool {
        guard let live = table.record(for: identity.pid) else { return false }
        return startTimesMatch(live.startTime, identity.startTime, tolerance: heuristic.weights.startTimeTolerance)
    }

    private func liveSnapshot() -> ProcessSnapshot {
        var processes: [Int32: ProcessRecord] = [:]
        for pid in table.allPIDs() {
            if let record = table.record(for: pid) { processes[pid] = record }
        }
        return ProcessSnapshot(takenAt: clock.now(), processes: processes)
    }

    // MARK: - 内部：worktree

    private func prune(_ command: PlannedCommand, repoRoot: String) -> CleanupOutcome {
        let label = "worktree prune \(repoRoot)"
        guard command.argv == ["git", "worktree", "prune"], command.cwd == repoRoot,
              repoRoot.hasPrefix("/") else { return refuse(label, .unsafePath) }
        return run(command, label: label)
    }

    private func removeDirectory(
        _ command: PlannedCommand, repoRoot: String, path: String, confirmed: Bool, freed: inout Int64
    ) -> CleanupOutcome {
        let label = "worktree remove \(path)"
        guard confirmed else { return refuse(label, .confirmationRequired) }
        guard repoRoot.hasPrefix("/"), path.hasPrefix("/"), command.cwd == repoRoot,
              command.argv == ["git", "worktree", "remove", path] else { return refuse(label, .unsafePath) }

        // 必须是 git 当前登记的、非主、非 locked 的 worktree，防止被用来删任意目录
        let scanner = WorktreeScanner(runner: runner, fileSystem: fileSystem)
        guard let entries = try? scanner.scan(repoAt: repoRoot),
              let entry = entries.first(where: { Self.samePath($0.path, path) }),
              !entry.isMain, !entry.isBare, !entry.isLocked else { return refuse(label, .unsafePath) }

        let before = fileSystem.allocatedSize(of: path)
        let outcome = run(command, label: label)
        if outcome == .done, !fileSystem.directoryExists(path) { freed = before }
        return outcome
    }

    private func run(_ command: PlannedCommand, label: String) -> CleanupOutcome {
        do {
            let result = try runner.run(command.argv, cwd: command.cwd)
            if result.status == 0 {
                log.log("cleanup: \(label) ok")
                return .done
            }
            log.log("cleanup: \(label) exit \(result.status)")
            return .failed(result.stderr.isEmpty ? "exit \(result.status)" : result.stderr)
        } catch {
            log.log("cleanup: \(label) failed: \(error)")
            return .failed("\(error)")
        }
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        func norm(_ p: String) -> String {
            var s = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
            while s.count > 1, s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return a == b || norm(a) == norm(b)
    }
}
