import MusterCore
import AppKit
import Foundation
import Combine

/// 面板状态与会话扫描的装配点；所有发布状态都在主线程更新。
@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var notice: String?
    @Published private(set) var isRefreshingSessions = false
    @Published var sessionSearch = ""
    @Published var sessionFilter: SessionActivityFilter = .all
    @Published var sessionGrouping: SessionGrouping = SessionGrouping(
        rawValue: UserDefaults.standard.string(forKey: "MusterSessionGrouping") ?? "") ?? .agent {
        didSet { UserDefaults.standard.set(sessionGrouping.rawValue, forKey: "MusterSessionGrouping") }
    }
    @Published var selectedSessionKey: String?
    @Published private(set) var searchFocusRequest = 0
    @Published private(set) var lastSessionRefresh: Date?
    @Published private(set) var resumingSessionKey: String?
    private var allScannedSessions: [Session] = []
    private var scopeObservation: AnyCancellable?
    private var lastAppliedAgentIDs: Set<String>?
    private var started = false
    private var sessionRescanRequested = false

    func focusSessionSearch(showInManagementWindow: Bool = true) {
        if showInManagementWindow { showsSettings = false }
        tab = .sessions
        searchFocusRequest += 1
    }

    func resetSessionFilters() {
        sessionSearch = ""
        sessionFilter = .all
    }
    private var scanTask: Task<Void, Never>?
    private var activityMonitor = SessionActivityMonitor()
    private let sessionStore = SessionStore()
    private let terminalJumper = TerminalJumper()
    private let notifier = NotificationService()
    private let scanners = AgentRegistry.transcriptScanners()
    private var diskTimer: Timer?

    enum Tab: String, CaseIterable {
        case projects = "Projects", sessions = "Sessions", agent = "Agent", environment = "Environment"

        /// rawValue 存在偏好里，保持不变；显示名单独映射
        var title: String {
            switch self {
            case .projects: return L10n.t("Projects")
            case .sessions: return L10n.t("Sessions")
            case .environment: return L10n.t("Cleanup")
            case .agent: return L10n.t("Agent")
            }
        }
    }

    @Published var tab: Tab = PanelModel.storedTab() {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) }
    }
    static let tabKey = "MusterLastTab"

    private static func storedTab() -> Tab {
        AgentNavigation.migrate(.standard)
        guard let raw = UserDefaults.standard.string(forKey: tabKey),
              let tab = Tab(rawValue: raw) else { return .sessions }
        return tab
    }

    @Published var showsSettings = false
    @Published var settingsSection: SettingsSection = .general
    @Published private(set) var settingsScrollRequest = 0
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
        AgentNavigation.migrate(.standard)
        let raw = UserDefaults.standard.stringArray(forKey: tabOrderKey) ?? []
        return raw.compactMap(Tab.init(rawValue:))
    }

    func toggleSettings() { showsSettings.toggle() }

    func showSettings(_ section: SettingsSection) {
        settingsSection = section
        showsSettings = true
        // An anchor can be clicked again after scrolling within the same section.
        settingsScrollRequest += 1
    }

    func openRepository() {
        if let url = URL(string: "https://github.com/EthanWFL/muster") { NSWorkspace.shared.open(url) }
    }

    let env = EnvironmentModel()
    let instructions: InstructionsModel
    let configuration: ConfigurationModel
    let diagnostics = DiagnosticsModel()
    let library: SessionLibraryModel
    let projects: ProjectsModel
    let agentWorkspace: AgentWorkspaceModel
    let agentSelection: AgentSelectionModel

    init(library: SessionLibraryModel? = nil, projectStore: ProjectStore = ProjectStore(),
         projectDefaults: UserDefaults = .standard, instructionsModel: InstructionsModel? = nil,
         configurationModel: ConfigurationModel? = nil, skillsModel: SkillsModel? = nil,
         detectInstalledAgents: @escaping @Sendable () -> [AgentDescriptor] = { AgentInstallation.detect() },
         settingsStore: SettingsStore? = nil) {
        let library = library ?? SessionLibraryModel()
        self.library = library
        instructions = instructionsModel ?? InstructionsModel()
        configuration = configurationModel ?? ConfigurationModel()
        projects = ProjectsModel(library: library, store: projectStore, defaults: projectDefaults)
        agentSelection = AgentSelectionModel(settings: settingsStore ?? SettingsStore.shared, detect: detectInstalledAgents)
        agentWorkspace = AgentWorkspaceModel(instructions: instructions, configuration: configuration, skills: skillsModel,
                                             selection: agentSelection)
        scopeObservation = agentSelection.$state.sink { [weak self] state in
            guard let self else { return }
            self.objectWillChange.send()
            guard self.lastAppliedAgentIDs != state.managedIDs else { return }
            self.lastAppliedAgentIDs = state.managedIDs
            self.applyAgentScope(state.managedIDs)
        }
    }

    private func applyAgentScope(_ ids: Set<String>) {
        sessions = allScannedSessions.filter { ids.contains($0.agent.rawValue) }
        library.managedAgentIDs = ids
        diagnostics.restrictToAgents(ids)
        env.restrictToAgents(ids)
        activityMonitor = SessionActivityMonitor()
        if let key = selectedSessionKey, !sessions.contains(where: { $0.key == key }) { selectedSessionKey = nil }
        if started { refreshSessions() }
    }

    func openLibrarySession(_ entry: LibrarySession) {
        guard !library.isSaving else { return }
        library.scope = entry.session.hasTranscript ? .history : .recent
        library.filter = .all
        sessionSearch = ""
        library.select(entry.id)
        showsSettings = false
        tab = .sessions
    }

    func start() {
        started = true
        agentSelection.refresh()
        library.load()
        projects.load()
        notifier.start()
        // Cleanup needs every live root for ownership checks, even roots hidden by the UI scope.
        env.sessionsProvider = { [weak self] in self?.allScannedSessions ?? [] }
        env.startSampling()
        refreshSessions()
        diskTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSessions() }
        }
    }

    func stop() {
        started = false
        sessionRescanRequested = false
        diskTimer?.invalidate()
        scanTask?.cancel()
        library.cancelImport()
        agentWorkspace.skills.cancel()
        env.stop()
    }

    func jumpToTerminal(_ session: Session) {
        guard agentSelection.manages(session.agent.rawValue) else { return }
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
        guard agentSelection.manages(session.agent.rawValue) else { return }
        guard let command = session.resumeCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        notice = L10n.t("Resume command copied · %@", command)
    }

    func continueSession(_ session: Session) {
        guard agentSelection.manages(session.agent.rawValue) else { return }
        if session.isProcessAlive { jumpToTerminal(session); return }
        guard resumingSessionKey == nil, session.resumeCommand != nil else { return }
        resumingSessionKey = session.key
        Task {
            defer { resumingSessionKey = nil }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SessionResumer().resume(session) }
            }.value
            switch result {
            case .success: notice = L10n.t("Resume command sent to a new Terminal window.")
            case .failure(let error):
                copyResume(session)
                notice = L10n.t(error.localizedDescription)
            }
        }
    }

    func refreshSessions() {
        guard !isRefreshingSessions else { sessionRescanRequested = true; return }
        isRefreshingSessions = true
        let ids = lastAppliedAgentIDs ?? agentSelection.state.managedIDs
        let scanners = scanners.filter { ids.contains($0.agent.rawValue) }
        let store = sessionStore
        scanTask = Task { [weak self] in
            let scan = await Task.detached(priority: .utility) {
                var transcripts: [Session] = []
                for scanner in scanners {
                    if let found = try? scanner.scan() { transcripts += found }
                }
                let processes = ids.isEmpty ? [] : AgentProcessScanner().scan()
                var list = store.refresh(transcripts: transcripts, processes: processes)
                    .filter { $0.state != .ended }
                var branches: [String: String] = [:]
                for cwd in Set(list.filter { ids.contains($0.agent.rawValue) }.map(\.cwd)) { branches[cwd] = SessionInsights.branch(cwd: cwd) }
                for index in list.indices { list[index].branch = branches[list[index].cwd] }
                return (list: list, transcripts: transcripts)
            }.value
            guard let self else { return }
            isRefreshingSessions = false
            guard !Task.isCancelled else { return }
            allScannedSessions = scan.list
            let currentIDs = agentSelection.state.managedIDs
            let list = scan.list.filter { currentIDs.contains($0.agent.rawValue) }
            sessions = list
            library.observe(transcripts: scan.transcripts.filter { currentIDs.contains($0.agent.rawValue) }, live: list)
            lastSessionRefresh = Date()
            let quiet = activityMonitor.newlyQuiet(list, now: Date())
            if !quiet.isEmpty { notifier.notifyQuiet(quiet) }
            if sessionRescanRequested { sessionRescanRequested = false; refreshSessions() }
        }
    }
}
