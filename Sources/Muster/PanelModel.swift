import MusterCore
import AppKit
import Foundation

/// 面板状态与会话扫描的装配点；所有发布状态都在主线程更新。
@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var notice: String?
    private var liveSessions: [Session] = []
    private let sessionStore = SessionStore()
    private let terminalJumper = TerminalJumper()
    private let notifier = NotificationService()
    private let scanners: [TranscriptScanner] = {
        let env = ProcessInfo.processInfo.environment
        func root(_ key: String, _ fallback: String, _ sub: String) -> URL {
            let base = env[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback)
            return base.appendingPathComponent(sub)
        }
        return [
            TranscriptScanner(agent: .claude, projectsRoot: root("CLAUDE_CONFIG_DIR", ".claude", "projects")),
            TranscriptScanner(agent: .codex, depth: 4, projectsRoot: root("CODEX_HOME", ".codex", "sessions")),
            TranscriptScanner(agent: .pi, projectsRoot: root("PI_CODING_AGENT_DIR", ".pi/agent", "sessions")),
        ]
    }()
    private var diskTimer: Timer?

    enum Tab: String, CaseIterable {
        case sessions = "Sessions", environment = "Environment",
             instructions = "Instructions", configuration = "Configuration"

        /// rawValue 存在偏好里，保持不变；显示名单独映射
        var title: String {
            switch self {
            case .sessions: return L10n.t("Sessions")
            case .environment: return L10n.t("Cleanup")
            case .instructions: return L10n.t("Rules")
            case .configuration: return L10n.t("Configuration")
            }
        }
    }

    @Published var tab: Tab = PanelModel.storedTab() {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) }
    }
    static let tabKey = "MusterLastTab"

    private static func storedTab() -> Tab {
        guard let raw = UserDefaults.standard.string(forKey: tabKey),
              let tab = Tab(rawValue: raw) else { return .sessions }
        return tab
    }

    @Published var showsSettings = false
    @Published var tabOrder: [Tab] = PanelModel.storedTabOrder() {
        didSet { UserDefaults.standard.set(tabOrder.map(\.rawValue), forKey: Self.tabOrderKey) }
    }
    static let tabOrderKey = "MusterTabOrder"

    var orderedTabs: [Tab] {
        var seen = Set<Tab>()
        return (tabOrder + Tab.allCases).filter { seen.insert($0).inserted }
    }

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

    func toggleSettings() { showsSettings.toggle() }

    let env = EnvironmentModel()
    let instructions = InstructionsModel()
    let configuration = ConfigurationModel()

    func start() {
        notifier.start()
        env.sessionsProvider = { [weak self] in self?.sessions ?? [] }
        env.startSampling()
        refreshSessions()
        diskTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSessions() }
        }
    }

    func stop() { diskTimer?.invalidate() }

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

    func copyResume(_ session: Session) {
        guard let command = session.resumeCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        notice = L10n.t("Resume command copied · %@", command)
    }

    /// 合并 transcript 和进程扫描，保留会话 ID、较早的开始时间及可用于终端跳转的 PID。
    private func refresh() {
        var list = sessionStore.sessions().filter { $0.state != .ended }
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
        for index in list.indices { list[index].branch = SessionInsights.branch(cwd: list[index].cwd) }
        let finished = SessionInsights.finished(from: sessions, to: list)
        sessions = list
        if !finished.isEmpty { notifier.notifyFinished(finished) }
    }

    func refreshSessions() {
        Task.detached(priority: .utility) { [weak self] in
            let found = AgentProcessScanner().scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                liveSessions = found
                refresh()
            }
        }
        let scanners = scanners
        let store = sessionStore
        Task.detached(priority: .utility) { [weak self] in
            for scanner in scanners {
                if let found = try? scanner.scan() { store.mergeDisk(found) }
            }
            await self?.refresh()
        }
    }
}
