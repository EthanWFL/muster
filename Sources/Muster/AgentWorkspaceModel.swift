import Foundation
import Combine
import MusterCore

@MainActor
final class AgentWorkspaceModel: ObservableObject {
    let instructions: InstructionsModel
    let configuration: ConfigurationModel
    let skills: SkillsModel
    let selection: AgentSelectionModel
    @Published private(set) var section: AgentSection
    @Published private(set) var agentID: String
    @Published private(set) var quickSection: QuickAgentSection
    @Published private(set) var quickRulesAgentID: String
    @Published private(set) var availableAgents: [AgentDescriptor] = []
    @Published private(set) var isCheckingAgents = false
    @Published var confirmsAgentChange = false
    @Published private(set) var agentChangeInQuickPanel = false
    private let defaults: UserDefaults
    private var pendingAgentID: String?
    private var observations = Set<AnyCancellable>()
    private var hasLoadedSkills = false
    private var quickConfigurationPrepared = false
    var detectionTask: Task<Void, Never>? { selection.refreshTask }

    init(instructions: InstructionsModel, configuration: ConfigurationModel, skills: SkillsModel? = nil,
         defaults: UserDefaults = .standard,
         detectInstalledAgents: @escaping @Sendable () -> [AgentDescriptor] = { AgentInstallation.detect() },
         selection: AgentSelectionModel? = nil) {
        self.instructions = instructions; self.configuration = configuration; self.skills = skills ?? SkillsModel()
        self.defaults = defaults
        self.selection = selection ?? AgentSelectionModel(settings: SettingsStore(defaults: defaults), detect: detectInstalledAgents)
        self.skills.restrictToAgents([])
        AgentNavigation.migrate(defaults)
        section = AgentSection(rawValue: defaults.string(forKey: "MusterAgentSection") ?? "") ?? .skills
        let id = defaults.string(forKey: "MusterSelectedAgent") ?? "all"
        agentID = AgentRegistry.agent(id) != nil ? id : "all"
        quickSection = QuickAgentSection(rawValue: defaults.string(forKey: "MusterQuickAgentSection") ?? "") ?? .rules
        quickRulesAgentID = defaults.string(forKey: "MusterQuickRulesAgent") ?? "all"
        self.selection.$isChecking.sink { [weak self] in self?.isCheckingAgents = $0 }.store(in: &observations)
        self.selection.$state.sink { [weak self] state in self?.applySelection(state) }.store(in: &observations)
    }
    func selectSection(_ section: AgentSection) {
        self.section = section
        defaults.set(section.rawValue, forKey: "MusterAgentSection")
        if section == .skills { hasLoadedSkills = true; skills.load() }
        if section == .configuration { alignWindowConfiguration() }
    }
    func selectAgent(_ id: String) {
        guard id != agentID, id == "all" || availableAgents.contains(where: { $0.id == id }) else { return }
        if configuration.dirty { pendingAgentID = id; agentChangeInQuickPanel = false; confirmsAgentChange = true; return }
        selectNow(id)
    }
    func cancelAgentChange() { pendingAgentID = nil; confirmsAgentChange = false }

    var quickConfigurationTargets: [AgentConfiguration] {
        let ids = Set(availableAgents.map(\.id))
        return configuration.targets.filter { ids.contains($0.id) }
    }
    func selectQuickSection(_ section: QuickAgentSection) {
        quickSection = section
        defaults.set(section.rawValue, forKey: "MusterQuickAgentSection")
        if section == .configuration { prepareQuickConfiguration() }
    }
    func selectQuickRulesAgent(_ id: String) {
        guard id == "all" || availableAgents.contains(where: { $0.id == id }) else { return }
        quickRulesAgentID = id
        defaults.set(id, forKey: "MusterQuickRulesAgent")
    }
    func prepareQuickConfiguration() {
        configuration.loadIfNeeded()
        guard !configuration.dirty else { return }
        let targets = quickConfigurationTargets
        let remembered = defaults.string(forKey: "MusterQuickConfigurationAgent")
        let preferred = quickConfigurationPrepared ? nil : targets.first { $0.id == remembered }
        let current = targets.first { $0.id == configuration.selected?.id }
        guard let target = preferred ?? current ?? targets.first(where: \.editable) ?? targets.first else { return }
        quickConfigurationPrepared = true
        selectQuickConfigurationNow(target.id)
    }
    func selectQuickConfigurationAgent(_ id: String) {
        guard quickConfigurationTargets.contains(where: { $0.id == id }) else { return }
        guard configuration.selected?.id != id else { return }
        if configuration.dirty { pendingAgentID = id; agentChangeInQuickPanel = true; confirmsAgentChange = true; return }
        selectQuickConfigurationNow(id)
    }
    private func selectQuickConfigurationNow(_ id: String) {
        guard let target = quickConfigurationTargets.first(where: { $0.id == id }) else { return }
        if configuration.selected?.id != id { configuration.select(target) }
        guard configuration.selected?.id == id else { return }
        defaults.set(id, forKey: "MusterQuickConfigurationAgent")
        quickConfigurationPrepared = true
        // Both surfaces share one configuration editor; keep the visible window label honest.
        if section == .configuration, agentID != "all" { setWindowAgent(id) }
    }
    func openQuickInWindow(skills: Bool = false) {
        let id = quickSection == .rules ? quickRulesAgentID : (configuration.selected?.id ?? "all")
        setWindowAgent(availableAgents.contains(where: { $0.id == id }) ? id : "all")
        selectSection(skills ? .skills : quickSection.windowSection)
        if !skills && quickSection == .rules { instructions.focusActiveSet() }
    }
    private func setWindowAgent(_ id: String) { agentID = id; defaults.set(id, forKey: "MusterSelectedAgent") }
    func resolveAgentChange(save: Bool) {
        guard let id = pendingAgentID else { return }
        if save { configuration.save(); guard !configuration.dirty else { return } }
        else { configuration.reload() }
        pendingAgentID = nil
        if agentChangeInQuickPanel { selectQuickConfigurationNow(id) }
        else { selectNow(id) }
    }
    func focusSkills() { selectSection(.skills); skills.focusSearch() }
    func load(syncWindowSelection: Bool = true) {
        instructions.loadIfNeeded(); configuration.loadIfNeeded()
        if syncWindowSelection && section == .skills { hasLoadedSkills = true; skills.load() }
        refreshAgents()
        if syncWindowSelection, section == .configuration { alignWindowConfiguration() }
    }
    private func alignWindowConfiguration() {
        guard agentID != "all" else { return }
        if configuration.dirty {
            if let current = configuration.selected?.id, availableAgents.contains(where: { $0.id == current }) { setWindowAgent(current) }
            else { setWindowAgent("all") }
        } else if let target = quickConfigurationTargets.first(where: { $0.id == agentID }), configuration.selected?.id != target.id {
            configuration.select(target)
        }
    }
    func refreshAgents() {
        selection.refresh()
    }
    private func applySelection(_ state: AgentSelectionState) {
        availableAgents = state.available
        let ids = Set(state.available.map(\.id))
        instructions.restrictToAgents(ids)
        configuration.restrictToAgents(ids)
        skills.restrictToAgents(ids)
        if state.hasDetected, agentID != "all", !ids.contains(agentID) {
            agentID = "all"
            defaults.set("all", forKey: "MusterSelectedAgent")
            // Keep the editor instance and its draft even if its Agent has gone away.
        }
        if state.hasDetected, quickRulesAgentID != "all", !ids.contains(quickRulesAgentID) { selectQuickRulesAgent("all") }
        if let pendingAgentID, !ids.contains(pendingAgentID), pendingAgentID != "all" {
            self.pendingAgentID = nil
            confirmsAgentChange = false
        }
        if hasLoadedSkills { skills.load(force: true) }
    }
    private func selectNow(_ id: String) {
        agentID = id; defaults.set(id, forKey: "MusterSelectedAgent")
        if let target = configuration.targets.first(where: { $0.id == id }) { configuration.select(target) }
    }
}
