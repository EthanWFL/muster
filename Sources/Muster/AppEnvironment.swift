import AppKit
import Combine
import Foundation
import MusterCore

/// Owns the long-lived feature models and the session scan loop.
/// `PanelModel` keeps navigation and per-surface selection, so adding a page
/// does not mean adding another stored property here.
@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var isRefreshingSessions = false
    @Published private(set) var lastSessionRefresh: Date?
    @Published private(set) var lastScanError: String?

    let library: SessionLibraryModel
    let projects: ProjectsModel
    let env = EnvironmentModel()
    let instructions: InstructionsModel
    let configuration: ConfigurationModel
    let diagnostics = DiagnosticsModel()
    let chat = ChatModel()
    let agentWorkspace: AgentWorkspaceModel
    let agentSelection: AgentSelectionModel

    /// Cleanup needs every live root, even agents hidden by the UI scope.
    private var allScannedSessions: [Session] = []
    private let sessionStore = SessionStore()
    private let notifier = NotificationService()
    private let scanners = AgentRegistry.transcriptScanners()
    private var activityMonitor = SessionActivityMonitor()
    private var scanTask: Task<Void, Never>?
    private var diskTimer: Timer?
    private var scopeObservation: AnyCancellable?
    private var lastAppliedAgentIDs: Set<String>?
    private var started = false
    private var sessionRescanRequested = false

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
            guard self.lastAppliedAgentIDs != state.managedIDs else { return }
            if self.lastAppliedAgentIDs != nil { self.chat.newConversation() }
            self.lastAppliedAgentIDs = state.managedIDs
            self.applyAgentScope(state.managedIDs)
        }
    }

    func start() {
        started = true
        agentSelection.refresh()
        library.load()
        projects.load()
        notifier.start()
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
        chat.stop()
        agentWorkspace.skills.cancel()
        env.stop()
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
                var failures: [String] = []
                for scanner in scanners {
                    do { transcripts += try scanner.scan() }
                    catch { failures.append(scanner.agent.displayName + ": " + error.localizedDescription) }
                }
                let processes = ids.isEmpty ? [] : AgentProcessScanner().scan()
                var list = store.refresh(transcripts: transcripts, processes: processes)
                    .filter { $0.state != .ended }
                var branches: [String: String] = [:]
                for cwd in Set(list.filter { ids.contains($0.agent.rawValue) }.map(\.cwd)) {
                    branches[cwd] = SessionInsights.branch(cwd: cwd)
                }
                for index in list.indices { list[index].branch = branches[list[index].cwd] }
                return (list: list, transcripts: transcripts, failures: failures)
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
            lastScanError = scan.failures.first
            diagnostics.recordScanFailures(scan.failures)
            let quiet = activityMonitor.newlyQuiet(list, now: Date())
            if !quiet.isEmpty { notifier.notifyQuiet(quiet) }
            if sessionRescanRequested { sessionRescanRequested = false; refreshSessions() }
        }
    }

    /// Activate the already-running client only; never start a terminal or copy a resume command.
    func openClient(_ session: Session, activate: (SessionClient) -> Bool = { client in
        let path = URL(fileURLWithPath: client.bundlePath).resolvingSymlinksInPath()
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.resolvingSymlinksInPath() == path
        }) else { return false }
        if let pane = client.paneURL, app.bundleIdentifier == "dev.warp.Warp-Stable",
           NSWorkspace.shared.urlForApplication(toOpen: pane)?.resolvingSymlinksInPath() == path,
           NSWorkspace.shared.open(pane) { return true }
        return app.activate(options: [])
    }) -> String? {
        guard agentSelection.manages(session.agent.rawValue), session.isProcessAlive, var client = session.client else { return nil }
        if client.paneURL != nil {
            let table = LibprocProcessTable()
            guard let pid = session.pid, let start = session.pidStartTime,
                  let process = table.record(for: pid), process.startTime == start else {
                return L10n.t("Could not activate %@. The client may have closed.", client.name)
            }
            // The shell or its registration can change between the scan and the click.
            guard let current = SessionClient.detect(for: process, record: table.record(for:)),
                  current.bundlePath == client.bundlePath else {
                return L10n.t("Could not activate %@. The client may have closed.", client.name)
            }
            client = current
        }
        return activate(client) ? nil : L10n.t("Could not activate %@. The client may have closed.", client.name)
    }

    private func applyAgentScope(_ ids: Set<String>) {
        sessions = allScannedSessions.filter { ids.contains($0.agent.rawValue) }
        library.managedAgentIDs = ids
        diagnostics.restrictToAgents(ids)
        env.restrictToAgents(ids)
        activityMonitor = SessionActivityMonitor()
        if started { refreshSessions() }
    }
}
