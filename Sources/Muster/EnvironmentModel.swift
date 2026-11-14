import MusterCore
import Foundation

struct DiagnosticsCleanupLog: CleanupLog {
    func log(_ message: String) { Diagnostics.default(message) }
}

/// 「环境」页的数据：端口 / 孤儿进程 / 失效 worktree 的清理计划与执行结果。
///
/// 孤儿判定需要连续 5 分钟的 CPU 采样历史，而面板一失焦就收起，所以采样器常驻（`startSampling`）。
/// 页面不可见时只做轻量的进程快照；可见时才做完整扫描（lsof 端口 + worktree + 出计划）。
/// 展示的命令文本与执行用的是同一批 `CleanupItem`（R7）；所有 kill 校验在 `CleanupExecutor` 内（R6）。
@MainActor
final class EnvironmentModel: ObservableObject {
    @Published private(set) var plan: CleanupPlan?
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var confirmed: Set<String> = []
    @Published private(set) var isBusy = false
    @Published private(set) var report: CleanupReport?
    @Published private(set) var isScanning = false
    @Published private(set) var forceKillReady: Set<ProcessIdentity> = []
    private(set) var scanTask: Task<Void, Never>?
    private(set) var reconcileTask: Task<Void, Never>?
    private(set) var executionTask: Task<Void, Never>?
    private var rescanRequested = false
    private var scopeRevision = 0
    private var managedAgentIDs: Set<String>?

    /// 由 `PanelModel` 注入，避免两边各存一份会话
    var sessionsProvider: @MainActor () -> [Session] = { [] }

    private let runner: CommandRunner
    private let table: ProcessTable
    private let clock: Clock
    private let detector: OrphanDetector
    private let planner = CleanupPlanner()
    private let executor: CleanupExecutor
    private var timer: Timer?

    static let samplingInterval: TimeInterval = 10

    init(runner: CommandRunner = CleanupCommandRunner(), table: ProcessTable = LibprocProcessTable(),
         detector: OrphanDetector = OrphanDetector(), clock: Clock = SystemClock(), executor: CleanupExecutor? = nil) {
        self.runner = runner
        self.table = table
        self.detector = detector
        self.clock = clock
        self.executor = executor ?? CleanupExecutor(table: table, runner: runner, clock: clock, log: DiagnosticsCleanupLog())
    }

    func stop() {
        timer?.invalidate()
        scanTask?.cancel()
        reconcileTask?.cancel()
        rescanRequested = false
    }

    func restrictToAgents(_ ids: Set<String>) {
        managedAgentIDs = ids
        detector.restrictToAgents(ids)
        scopeRevision += 1
        plan = nil
        selected = []; confirmed = []; seen = []
        rescanRequested = isVisible
        if isVisible, !isScanning, !isBusy { scan() }
    }

    // MARK: - 采样

    /// app 启动时调用一次
    func startSampling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.samplingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// 页面出现 / 消失时由视图通知；出现时立即做一次完整扫描
    func setVisible(_ visible: Bool, owner: UUID) {
        let wasVisible = isVisible
        if visible { visibleOwners.insert(owner) } else { visibleOwners.remove(owner) }
        if isVisible && !wasVisible { scan() }
    }

    private var visibleOwners: Set<UUID> = []
    var isVisible: Bool { !visibleOwners.isEmpty }

    private func tick() {
        if isVisible { scan() } else { sampleOnly() }
    }

    /// Keep sampling tracked children even after the last parent session exits.
    func sampleOnly() { startScan(full: false) }

    func scan() { startScan(full: true) }

    private func startScan(full: Bool) {
        guard !isBusy else { return }
        guard !isScanning else {
            if full { rescanRequested = true }
            return
        }
        let sessions = sessionsProvider()
        guard full || detector.needsSampling(sessions: sessions) else { return }
        isScanning = true
        let revision = scopeRevision
        let ids = managedAgentIDs
        let (runner, table, clock, detector, planner) = (runner, table, clock, detector, planner)
        scanTask = Task { [weak self] in
            let plan = await Task.detached(priority: .utility) { () -> CleanupPlan? in
                let scanner = ProcessScanner(table: table, runner: runner, clock: clock)
                let snapshot = scanner.snapshot()
                detector.observe(snapshot: snapshot, sessions: sessions)
                guard full else { return nil }
                let ports = (try? scanner.listeningPorts()) ?? []
                let projects = Array(Set(sessions.filter { $0.state != .ended && (ids?.contains($0.agent.rawValue) ?? true) }.map(\.cwd).filter { !$0.isEmpty }))
                let worktrees = WorktreeScanner(runner: runner).scanAll(projects: projects)
                return planner.plan(sessions: sessions, snapshot: snapshot, ports: ports,
                                    orphans: detector.candidates(), worktrees: worktrees, agentIDs: ids)
            }.value
            guard let self else { return }
            isScanning = false
            guard !Task.isCancelled else { return }
            if revision == scopeRevision, let plan { apply(plan) }
            if rescanRequested {
                rescanRequested = false
                scan()
            }
        }
    }

    private var seen: Set<String> = []

    private func apply(_ plan: CleanupPlan) {
        let ids = Set(plan.items.map(\.id))
        // 新出现的项按默认规则预选；已有的保持用户的选择；不确定/需确认的项永不预选
        for item in plan.items where !seen.contains(item.id) && item.isPreselected { selected.insert(item.id) }
        seen = ids
        selected.formIntersection(ids)
        confirmed.formIntersection(ids)
        self.plan = plan
    }

    // MARK: - 选择

    var items: [CleanupItem] { plan?.items ?? [] }
    var selectedItems: [CleanupItem] { items.filter { selected.contains($0.id) } }
    var unconfirmedCount: Int { selectedItems.filter { $0.needsExplicitConfirmation && !confirmed.contains($0.id) }.count }
    var canExecute: Bool { !selectedItems.isEmpty && unconfirmedCount == 0 && !isBusy && !isScanning && report?.awaitingExit.isEmpty != false }

    /// R7：显示给用户的命令，就是将要执行的这批 item 的命令
    var commandTexts: [String] { selectedItems.map { $0.command.displayText } }

    func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
            confirmed.remove(id)
        } else {
            selected.insert(id)
        }
    }

    func toggleConfirmed(_ id: String) {
        guard selected.contains(id) else { return }
        if confirmed.contains(id) { confirmed.remove(id) } else { confirmed.insert(id) }
    }

    // MARK: - 执行

    func execute() {
        guard canExecute, let plan else { return }
        isBusy = true
        let request = CleanupRequest(selected: selected, confirmed: confirmed)
        let sessions = sessionsProvider()
        let executor = self.executor
        executionTask = Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) {
                executor.execute(plan: plan, request: request, sessions: sessions)
            }.value
            self?.finish(report)
        }
    }

    private func finish(_ report: CleanupReport) {
        self.report = report
        isBusy = false
        // 已处理的项会在下次扫描后消失；被拒绝的项保留，让用户看到原因
        selected.subtract(report.entries.filter { $0.outcome == .done || $0.outcome == .termSent }.map(\.itemID))
        startReconciliation()
        scan()
    }

    /// Update the report until process identity checks confirm exit, including while hidden.
    private func startReconciliation() {
        reconcileTask?.cancel()
        let executor = executor
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let current = self?.report, !current.awaitingExit.isEmpty else { return }
                let (updated, ready) = await Task.detached(priority: .utility) {
                    var updated = current
                    executor.reconcile(&updated)
                    let ready = Set(updated.awaitingExit.filter { executor.canForceKill($0) }.map(\.identity))
                    return (updated, ready)
                }.value
                guard !Task.isCancelled else { return }
                self?.report = updated
                self?.forceKillReady = ready
                if updated.awaitingExit.isEmpty {
                    self?.scan()
                    return
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }

    /// Called only after the UI's separate force-quit confirmation.
    func forceKill(_ target: ProcessTarget) {
        guard !isBusy, forceKillReady.contains(target.identity),
              report?.awaitingExit.contains(where: { $0.identity == target.identity }) == true else { return }
        isBusy = true
        reconcileTask?.cancel()
        forceKillReady.remove(target.identity)
        let executor = executor
        executionTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                executor.forceKill(target, userConfirmed: true)
            }.value
            guard let self else { return }
            let id = CleanupItem(action: .terminate(target), title: "").id
            if let index = report?.entries.firstIndex(where: { $0.itemID == id }), let old = report?.entries[index] {
                report?.entries[index] = CleanupEntry(itemID: old.itemID, title: old.title,
                    commandText: "kill -KILL \(target.identity.pid)", outcome: outcome == .done ? .killSent : outcome)
            }
            isBusy = false
            startReconciliation()
        }
    }

    func dismissReport() {
        guard report?.awaitingExit.isEmpty != false else { return }
        report = nil
        forceKillReady = []
    }
}
