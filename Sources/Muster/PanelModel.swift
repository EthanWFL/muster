import AppKit
import Combine
import Foundation
import MusterCore

/// Navigation and per-surface selection. Long-lived feature models and the
/// session scan loop live in `AppEnvironment`.
@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var sessions: [Session] = []
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
    @Published private(set) var lastScanError: String?

    let environment: AppEnvironment
    private var environmentObservations = Set<AnyCancellable>()

    var projects: ProjectsModel { environment.projects }
    var library: SessionLibraryModel { environment.library }
    var env: EnvironmentModel { environment.env }
    var instructions: InstructionsModel { environment.instructions }
    var configuration: ConfigurationModel { environment.configuration }
    var diagnostics: DiagnosticsModel { environment.diagnostics }
    var chat: ChatModel { environment.chat }
    var agentWorkspace: AgentWorkspaceModel { environment.agentWorkspace }
    var agentSelection: AgentSelectionModel { environment.agentSelection }

    func focusSessionSearch(showInManagementWindow: Bool = true) {
        if showInManagementWindow { showsSettings = false }
        tab = .sessions
        searchFocusRequest += 1
    }

    func resetSessionFilters() {
        sessionSearch = ""
        sessionFilter = .all
    }

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

        var sidebarTitle: String {
            self == .sessions ? L10n.t("Session history") : title
        }

        var symbol: String {
            switch self {
            case .projects: return "folder"
            case .sessions: return "clock"
            case .environment: return "sparkles"
            case .agent: return "terminal"
            }
        }
    }

    /// One table drives the sidebar and the content area.
    enum Destination: Hashable, Identifiable {
        case workspace(Tab)
        case chat
        case wheel
        case settings

        var id: String {
            switch self {
            case .workspace(let tab): return "workspace." + tab.rawValue
            case .chat: return "chat"
            case .wheel: return "wheel"
            case .settings: return "settings"
            }
        }

        var title: String {
            switch self {
            case .workspace(let tab): return tab.title
            case .chat: return L10n.t("AI chat")
            case .wheel: return L10n.t("Wheel setup")
            case .settings: return L10n.t("Settings")
            }
        }

        var sidebarTitle: String {
            switch self {
            case .workspace(let tab): return tab.sidebarTitle
            case .chat: return L10n.t("AI chat")
            case .wheel: return L10n.t("Wheel setup")
            case .settings: return L10n.t("Settings")
            }
        }

        var symbol: String {
            switch self {
            case .workspace(let tab): return tab.symbol
            case .chat: return "bubble.left"
            case .wheel: return "circle.grid.cross"
            case .settings: return "gearshape"
            }
        }
    }

    var destination: Destination {
        switch managementPage {
        case .chat: return .chat
        case .wheel: return .wheel
        case .settings: return .settings
        case .workspace: return .workspace(tab)
        }
    }

    var workspaceDestinations: [Destination] {
        orderedTabs.flatMap { tab -> [Destination] in
            tab == .sessions ? [.workspace(tab), .chat] : [.workspace(tab)]
        }
    }

    func select(_ destination: Destination) {
        switch destination {
        case .workspace(let tab):
            showsSettings = false
            self.tab = tab
        case .chat:
            managementPage = .chat
        case .wheel:
            managementPage = .wheel
        case .settings:
            managementPage = .settings
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

    enum ManagementPage { case workspace, chat, settings, wheel }
    @Published var managementPage: ManagementPage = .workspace
    var showsSettings: Bool {
        get { managementPage == .settings }
        set { managementPage = newValue ? .settings : .workspace }
    }
    @Published var wheelSection: WheelSettingsSection = .inner
    @Published private(set) var wheelScrollRequest = 0
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

    func showWheelSection(_ section: WheelSettingsSection) {
        wheelSection = section
        managementPage = .wheel
        wheelScrollRequest += 1
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

    /// Areas that would lose edits if the app terminates now.
    var unsavedAreas: [String] {
        var areas: [String] = []
        if library.dirty { areas.append(L10n.t("Session details")) }
        if instructions.isDirty { areas.append(L10n.t("Instructions")) }
        if configuration.dirty { areas.append(L10n.t("Agent configuration")) }
        if agentWorkspace.skills.unsaved || agentWorkspace.skills.dirty
            || agentWorkspace.skills.deploymentDirty || agentWorkspace.skills.batchDirty {
            areas.append(L10n.t("Skill draft"))
        }
        return areas
    }

    init(library: SessionLibraryModel? = nil, projectStore: ProjectStore = ProjectStore(),
         projectDefaults: UserDefaults = .standard, instructionsModel: InstructionsModel? = nil,
         configurationModel: ConfigurationModel? = nil, skillsModel: SkillsModel? = nil,
         detectInstalledAgents: @escaping @Sendable () -> [AgentDescriptor] = { AgentInstallation.detect() },
         settingsStore: SettingsStore? = nil) {
        environment = AppEnvironment(library: library, projectStore: projectStore,
            projectDefaults: projectDefaults, instructionsModel: instructionsModel,
            configurationModel: configurationModel, skillsModel: skillsModel,
            detectInstalledAgents: detectInstalledAgents, settingsStore: settingsStore)
        environment.$sessions.sink { [weak self] sessions in
            self?.sessions = sessions
            if let key = self?.selectedSessionKey, !sessions.contains(where: { $0.key == key }) {
                self?.selectedSessionKey = nil
            }
        }.store(in: &environmentObservations)
        environment.$isRefreshingSessions.sink { [weak self] in self?.isRefreshingSessions = $0 }.store(in: &environmentObservations)
        environment.$lastSessionRefresh.sink { [weak self] in self?.lastSessionRefresh = $0 }.store(in: &environmentObservations)
        environment.$lastScanError.sink { [weak self] in self?.lastScanError = $0 }.store(in: &environmentObservations)
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

    func start() { environment.start() }
    func stop() { environment.stop() }
    func refreshSessions() { environment.refreshSessions() }

    func openClient(_ session: Session, activate: @escaping (SessionClient) -> Bool = { client in
        let path = URL(fileURLWithPath: client.bundlePath).resolvingSymlinksInPath()
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.resolvingSymlinksInPath() == path
        }) else { return false }
        if let pane = client.paneURL, app.bundleIdentifier == "dev.warp.Warp-Stable",
           NSWorkspace.shared.urlForApplication(toOpen: pane)?.resolvingSymlinksInPath() == path,
           NSWorkspace.shared.open(pane) { return true }
        return app.activate(options: [])
    }) -> String? {
        environment.openClient(session, activate: activate)
    }
}
