import MusterCore
import MusterProtocol
import AppKit
import Foundation

/// UI 与 `AgentDaemon` / `SocketServer` 之间的唯一装配点。
/// 所有 `@Published` 只在主线程更新；daemon 的变更回调会合并后再切回主线程。
@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var pending: [ToolCall] = []
    @Published private(set) var sessions: [Session] = []
    /// 进程扫出来的"正开着"的会话，和 hook/磁盘的会话在 refresh 里合并
    private var liveSessions: [Session] = []
    @Published var selection: String?
    /// 面板底部的一行提示（socket 启动失败、操作失败等）
    @Published private(set) var notice: String?
    /// 非 nil 表示正在编辑拒绝原因（R3：拒绝必须带原因，默认预填，可编辑）
    @Published var denyDraft: String?
    /// nil = 未知（配置读取失败）
    @Published private(set) var hookInstalled: Bool?
    /// 等待用户二次确认的配置改动（会写 ~/.claude/settings.json）
    @Published private(set) var pendingHookAction: HookAction?
    /// 等待确认的永久放行规则（R4：展示原文，确认后才写 settings）
    @Published private(set) var pendingPermanentAllow: PermanentAllowPrompt?

    struct PermanentAllowPrompt: Identifiable {
        let callID: String
        let rule: PermanentRule
        var id: String { callID }
    }

    private let terminalJumper = TerminalJumper()
    private let notifications = NotificationService()
    private var notifiedCallIDs: Set<String> = []

    /// Set by the app delegate so a notification click can reveal the panel.
    var onOpenPanelRequest: (() -> Void)? {
        didSet { notifications.onOpen = onOpenPanelRequest }
    }

    enum HookAction { case install, uninstall }

    enum Tab: String, CaseIterable {
        case approvals = "Approvals", sessions = "Sessions", environment = "Environment",
             instructions = "Instructions"

        /// 审批页暂时下线：只接了 Claude，且全拦每个调用都要等 90 秒。
        /// 等风险门（只拦高危）和多 agent 钩子做完再打开。
        var isHidden: Bool { self == .approvals }

        var title: String {
            switch self {
            case .approvals: return L10n.t("Approvals")
            case .sessions: return L10n.t("Sessions")
            case .environment: return L10n.t("Environment")
            case .instructions: return L10n.t("Instructions")
            }
        }
    }
    /// 上次停在哪个 tab，下次点开图标回到这里
    @Published var tab: Tab = PanelModel.storedTab() {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) }
    }

    static let tabKey = "MusterLastTab"

    private static func storedTab() -> Tab {
        guard let raw = UserDefaults.standard.string(forKey: tabKey),
              let tab = Tab(rawValue: raw), !tab.isHidden else { return .sessions }
        return tab
    }
    /// 面板里正在显示设置页（不再是独立窗口）
    @Published var showsSettings = false

    /// 顶部 tab 的展示顺序（设置页可调），空表示按默认顺序
    @Published var tabOrder: [Tab] = PanelModel.storedTabOrder() {
        didSet { UserDefaults.standard.set(tabOrder.map(\.rawValue), forKey: Self.tabOrderKey) }
    }

    static let tabOrderKey = "MusterTabOrder"

    /// 实际渲染用的顺序：存过的顺序 + 补齐新增的 tab
    var orderedTabs: [Tab] {
        let known = Set(Tab.allCases.filter { !$0.isHidden })
        var seen = Set<Tab>()
        var out: [Tab] = []
        for tab in tabOrder where known.contains(tab) && seen.insert(tab).inserted { out.append(tab) }
        for tab in Tab.allCases where !tab.isHidden && seen.insert(tab).inserted { out.append(tab) }
        return out
    }

    /// 拖动排序：把第 from 项挪到第 to 项的位置
    func moveTab(from: Int, to: Int) {
        var order = orderedTabs
        guard order.indices.contains(from), order.indices.contains(to), from != to else { return }
        let item = order.remove(at: from)
        order.insert(item, at: to)
        tabOrder = order
    }

    private static func storedTabOrder() -> [Tab] {
        let raw = UserDefaults.standard.stringArray(forKey: tabOrderKey) ?? []
        return raw.compactMap(Tab.init(rawValue:))
    }

    /// 倒计时线的总长；与 `ApprovalStore.timeout` 一致
    var approvalTimeout: TimeInterval { daemon.approvals.timeout }

    /// 高危命令默认不提供「允许同类」（见 IMPLEMENTATION.md M2 2.6），由 store 决定
    func canAllowSimilar(_ id: String) -> Bool { daemon.approvals.canOfferAllowSimilar(id: id) }

    /// 设置并入面板：再点一次退回主视图
    func toggleSettings() {
        showsSettings.toggle()
        if showsSettings { denyDraft = nil }
    }

    func lastToolSummary(for sessionID: String) -> String? {
        daemon.sessions.toolSummaries(for: sessionID).last
    }

    let daemon = AgentDaemon()
    let env = EnvironmentModel()
    let instructions = InstructionsModel()
    private var server: SocketServer?
    private var adapter: ClaudeAdapter?
    private var installer: ClaudeHookInstaller? { adapter?.installer }
    private var diskTimer: Timer?
    private var refreshScheduled = false

    static let deniedReason = "Denied from Muster"

    func start() {
        notifications.start()
        env.sessionsProvider = { [weak self] in self?.sessions ?? [] }
        env.startSampling()
        daemon.onChange = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        daemon.start()
        startServer()
        startDiskScan()
        refresh()
    }

    func stop() {
        diskTimer?.invalidate()
        server?.stop()
        daemon.stop()
    }

    // MARK: - 决策

    func allowSelected() { resolve { try self.daemon.approvals.allow(id: $0) } }

    func allowSimilarSelected() {
        guard let id = selection, daemon.approvals.canOfferAllowSimilar(id: id) else { return }
        resolve { try self.daemon.approvals.allowSimilar(id: $0) }
    }

    func beginDeny() {
        guard selection != nil else { return }
        denyDraft = Self.deniedReason
    }

    func confirmDeny() {
        guard let draft = denyDraft else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        denyDraft = nil
        resolve { try self.daemon.approvals.deny(id: $0, reason: trimmed.isEmpty ? Self.deniedReason : trimmed) }
    }

    func cancelDeny() { denyDraft = nil }

    /// R4：只为当前请求生成一条精确规则；不能安全表达时不提供该操作。
    func canAlwaysAllow(_ id: String) -> Bool {
        daemon.approvals.permanentRuleSnippet(id: id) != nil
    }

    func beginPermanentAllow() {
        guard let id = selection,
              let snippet = daemon.approvals.permanentRuleSnippet(id: id),
              let rule = PermanentRule.parse(snippet) else { return }
        denyDraft = nil
        pendingPermanentAllow = PermanentAllowPrompt(callID: id, rule: rule)
    }

    func cancelPermanentAllow() { pendingPermanentAllow = nil }

    func clearPermanentAllow() { pendingPermanentAllow = nil }

    /// 先写 settings（安装器负责备份和原子写），成功了才放行，避免界面说“已永久允许”但文件没变。
    func confirmPermanentAllow() {
        guard let prompt = pendingPermanentAllow, let installer else { return }
        do {
            try installer.addAllowRule(prompt.rule.text)
        } catch {
            notice = L10n.t("Could not save permanent rule: %@", String(describing: error))
            return
        }
        reloadPermanentRules()
        do {
            daemon.resolve(try daemon.approvals.allow(id: prompt.callID))
            pendingPermanentAllow = nil
            notice = L10n.t("Always allowed · %@ saved to %@", prompt.rule.text, settingsPath)
        } catch {
            notice = L10n.t("Rule saved, but the request is no longer pending")
        }
        refresh()
    }

    // MARK: - 跳转到终端

    func jumpToTerminal() {
        guard let id = selection,
              let call = pending.first(where: { $0.id == id }),
              let session = daemon.sessions.session(id: call.sessionID) else {
            notice = L10n.t("Session is not active")
            return
        }
        jumpToTerminal(session)
    }

    func jumpToTerminal(_ session: Session) {
        let jumper = terminalJumper
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = jumper.jump(to: session)
            await MainActor.run { [weak self] in self?.applyJumpResult(result) }
        }
    }

    private func applyJumpResult(_ result: TerminalJumpResult) {
        switch result {
        case .focused(let app, let tty):
            notice = L10n.t("Focused %@ · %@", app, tty)
        case .copied(let command):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
            notice = L10n.t("Terminal window not found · %@ copied", command)
        }
    }

    func moveSelection(by delta: Int) {
        guard !pending.isEmpty else { return }
        pendingPermanentAllow = nil
        let current = pending.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : pending.count)
        let next = min(max(current + delta, 0), pending.count - 1)
        selection = pending[next].id
    }

    private func resolve(_ action: (String) throws -> ApprovalResolution) {
        guard let id = selection else { return }
        do {
            daemon.resolve(try action(id))
            notice = nil
        } catch {
            // 条目可能刚好超时或连接已断：刷新即可，不算错误
            notice = L10n.t("Request is no longer pending")
        }
        refresh()
    }

    // MARK: - Hook 安装

    var settingsPath: String { installer?.settingsURL.path ?? "~/.claude/settings.json" }

    func requestHook(_ action: HookAction) { pendingHookAction = action }

    func cancelHookAction() { pendingHookAction = nil }

    /// 只在用户点了确认后调用；安装器自带备份、原子写，遇到未知 schema 会拒绝写入
    func confirmHookAction() {
        guard let action = pendingHookAction, let installer else { return }
        pendingHookAction = nil
        do {
            switch action {
            case .install: try installer.install()
            case .uninstall: try installer.uninstall()
            }
            notice = nil
        } catch {
            notice = L10n.t("Hook change failed: %@", String(describing: error))
        }
        refreshHookState()
        reloadPermanentRules()
    }

    /// settings 是唯一真相来源；每次写入后重新解析，避免内存规则和文件漂移。
    private func reloadPermanentRules() {
        guard let installer else { return }
        let texts = (try? installer.allowRules()) ?? []
        daemon.approvals.replacePermanentRules(texts.compactMap(PermanentRule.parse))
    }

    private func refreshHookState() {
        hookInstalled = try? installer?.isInstalled()
    }

    // MARK: - 刷新

    /// 一次 hook 事件可能连发多次回调，合并成一次刷新
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            refreshScheduled = false
            refresh()
        }
    }

    private func refresh() {
        pending = daemon.approvals.pending
        sessions = mergedSessions()
        let liveIDs = Set(pending.map(\.id))
        notifiedCallIDs.formIntersection(liveIDs)
        // 审批页隐藏时提醒没有意义：点开也处理不了，只会变成噪音
        for call in pending where !Tab.approvals.isHidden && !notifiedCallIDs.contains(call.id) {
            notifiedCallIDs.insert(call.id)
            notifications.notify(call)
        }
        if let prompt = pendingPermanentAllow, !pending.contains(where: { $0.id == prompt.callID }) {
            pendingPermanentAllow = nil
        }
        if let s = selection, pending.contains(where: { $0.id == s }) { return }
        selection = pending.first?.id
    }

    /// 进程扫到的才算"开着"；能对上 pid 或目录的就并进已有那条，保留 hook 给的状态和 id
    private func mergedSessions() -> [Session] {
        var list = daemon.sessions.sessions().filter { $0.state != .ended }
        for live in liveSessions {
            if let index = list.firstIndex(where: {
                $0.agent == live.agent
                    && ($0.pid == live.pid || ($0.pid == nil && $0.cwd == live.cwd))
            }) {
                list[index].pid = live.pid
                list[index].pidStartTime = live.pidStartTime
                list[index].startedAt = min(list[index].startedAt, live.startedAt)
            } else if !list.contains(where: { $0.id == live.id }) {
                list.append(live)
            }
        }
        return list
    }

    /// 手动刷新：马上重扫进程和磁盘
    func refreshSessions() {
        scanLive()
        scanDisk()
    }

    private func scanLive() {
        Task.detached(priority: .utility) {
            let found = AgentProcessScanner().scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                liveSessions = found
                refresh()
            }
        }
    }

    // MARK: - 启动

    private func startServer() {
        let path = SocketPath.resolve(environment: ProcessInfo.processInfo.environment)
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let server = SocketServer(path: path, handler: daemon)
            try server.start()
            self.server = server
        } catch {
            // 没有 socket 时 hook 连不上，agent 照常走原生确认，所以这里只提示、不退出
            notice = L10n.t("Approval socket unavailable: %@", String(describing: error))
        }
    }

    private func startDiskScan() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/Muster")
        adapter = ClaudeAdapter(
            projectsRoot: home.appendingPathComponent(".claude/projects"),
            settingsURL: home.appendingPathComponent(".claude/settings.json"),
            backupRoot: support.appendingPathComponent("backups"),
            // hook 与 app 可执行文件同目录（.build/debug 或 .app/Contents/MacOS）
            hookExecutable: (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
                .deletingLastPathComponent().appendingPathComponent("muster-hook").path)
        refreshHookState()
        reloadPermanentRules()
        scanDisk()
        scanLive()
        // 低频兜底；实时状态来自 hook 事件
        diskTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanDisk()
                self?.scanLive()
            }
        }
    }

    private func scanDisk() {
        guard let adapter else { return }
        // 外部也可能改 settings；15s 一次的扫描顺便刷新永久规则，撤销能及时生效
        reloadPermanentRules()
        let store = daemon.sessions
        // 扫描读文件，放到后台，避免卡面板
        Task.detached(priority: .utility) { [weak self] in
            if let found = try? adapter.sessions() { store.mergeDisk(found) }
            await self?.refresh()
        }
    }
}
