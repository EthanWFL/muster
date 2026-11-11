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

    /// 由 `PanelModel` 注入，避免两边各存一份会话
    var sessionsProvider: @MainActor () -> [Session] = { [] }

    private let runner = CleanupCommandRunner()
    private let detector = OrphanDetector()
    private let planner = CleanupPlanner()
    private let executor: CleanupExecutor
    private var timer: Timer?

    static let samplingInterval: TimeInterval = 10

    init() {
        executor = CleanupExecutor(runner: runner, log: DiagnosticsCleanupLog())
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
    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible { scan() }
    }

    private var isVisible = false

    private func tick() {
        if isVisible { scan() } else { sampleOnly() }
    }

    /// 只喂孤儿检测器：一次 libproc 快照，不跑 lsof / git。没有存活会话时不采样。
    private func sampleOnly() {
        guard !isBusy else { return }
        let sessions = sessionsProvider()
        guard sessions.contains(where: { $0.state != .ended }) else { return }
        let (runner, detector) = (self.runner, self.detector)
        Task.detached(priority: .background) {
            detector.observe(snapshot: ProcessScanner(runner: runner).snapshot(), sessions: sessions)
        }
    }

    func scan() {
        guard !isBusy else { return }
        let sessions = sessionsProvider()
        let (runner, detector, planner) = (self.runner, self.detector, self.planner)
        Task.detached(priority: .utility) { [weak self] in
            let scanner = ProcessScanner(runner: runner)
            let snapshot = scanner.snapshot()
            let ports = (try? scanner.listeningPorts()) ?? []
            detector.observe(snapshot: snapshot, sessions: sessions)
            let projects = Array(Set(sessions.filter { $0.state != .ended }.map(\.cwd).filter { !$0.isEmpty }))
            let worktrees = WorktreeScanner(runner: runner).scanAll(projects: projects)
            let plan = planner.plan(
                sessions: sessions, snapshot: snapshot, ports: ports,
                orphans: detector.candidates(), worktrees: worktrees)
            await self?.apply(plan)
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
    var canExecute: Bool { !selectedItems.isEmpty && unconfirmedCount == 0 && !isBusy }

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
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = executor.execute(plan: plan, request: request, sessions: sessions)
            await self?.finish(report)
        }
    }

    private func finish(_ report: CleanupReport) {
        self.report = report
        isBusy = false
        // 已处理的项会在下次扫描后消失；被拒绝的项保留，让用户看到原因
        selected.subtract(report.entries.filter { $0.outcome == .done || $0.outcome == .termSent }.map(\.itemID))
        scan()
    }

    func dismissReport() { report = nil }
}
