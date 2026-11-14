import Foundation
import Testing
import MusterCore
@testable import Muster

@Suite @MainActor struct AgentSelectionTests {
    @Test func customSelectionPersistsIncludingEmptyAndDoesNotAddNewInstallations() async throws {
        let suite = "managed-agents-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let detector = SelectionDetector(["claude", "codex"])
        let model = AgentSelectionModel(settings: store, detect: { detector.detect() })
        model.refresh(); await model.refreshTask?.value
        #expect(model.state.managedIDs == ["claude", "codex"])
        #expect(model.isAutomatic)
        model.setManaged("codex", false)
        #expect(store.managedAgentIDs == ["claude"])
        detector.set(["claude", "codex", "pi"])
        model.refresh(); await model.refreshTask?.value
        #expect(model.state.managedIDs == ["claude"])
        let reopened = AgentSelectionModel(settings: SettingsStore(defaults: defaults), detect: { detector.detect() })
        reopened.refresh(); await reopened.refreshTask?.value
        #expect(reopened.state.managedIDs == ["claude"])
        reopened.selectNone()
        #expect(SettingsStore(defaults: defaults).managedAgentIDs == [])
        reopened.refresh(); await reopened.refreshTask?.value
        #expect(reopened.state.managedIDs.isEmpty)
        reopened.followDetected()
        #expect(reopened.state.managedIDs == ["claude", "codex", "pi"])
        #expect(SettingsStore(defaults: defaults).managedAgentIDs == nil)
    }

    @Test func oneSelectionFiltersWorkspaceHistoryProjectsAndWritesWithoutDeletingDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "agent-scope-integration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let project = root.appendingPathComponent("project")
        let configFile = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalConfig = "model = \"old\"\n"
        try originalConfig.write(to: configFile, atomically: true, encoding: .utf8)
        let sessions = [Session(id: "a", agent: .claude, cwd: project.path, startedAt: Date()),
                        Session(id: "b", agent: .codex, cwd: project.path, startedAt: Date())]
        let catalog = SessionCatalog(url: root.appendingPathComponent("sessions.json"))
        _ = try await catalog.ingest(sessions)
        for session in sessions { _ = try await catalog.edit(session.key, expected: .init(), annotation: .init(needsAttention: true)) }
        let library = SessionLibraryModel(catalog: catalog, historyScanner: { _ in sessions })
        let projectStore = ProjectStore(url: root.appendingPathComponent("projects.json"))
        _ = try await projectStore.add(project.path)
        let rulesSync = InstructionSync(paths: InstructionPaths(support: root.appendingPathComponent("rules").path))
        try rulesSync.saveText("Shared rule", setID: InstructionSet.defaultID)
        let rules = InstructionsModel(sync: rulesSync, detectTargets: { InstructionTargets.detect(home: root.path, environment: [:]) })
        let configuration = ConfigurationModel(store: AgentConfigurationStore(backupDirectory: root.appendingPathComponent("backups")),
            presetStore: ConfigurationPresetStore(url: root.appendingPathComponent("presets.json")),
            detectTargets: { AgentConfiguration.detect(home: root.path, environment: [:]) })
        let skillStore = SkillLibrary(root: root.appendingPathComponent("skills-library"))
        let targets = AgentRegistry.skillTargets(home: root.path, environment: [:])
        let skill = try #require(try await skillStore.create(name: "review", description: "Review").skills.first)
        _ = try await skillStore.apply(skillStore.plan(skill.id, desired: ["codex": .copy], targets: targets))
        let skills = SkillsModel(library: skillStore, targets: targets)
        let panel = PanelModel(library: library, projectStore: projectStore, projectDefaults: defaults, instructionsModel: rules,
            configurationModel: configuration, skillsModel: skills,
            detectInstalledAgents: { AgentRegistry.all.filter { ["claude", "codex"].contains($0.id) } }, settingsStore: settings)
        panel.agentWorkspace.load(); await panel.agentWorkspace.detectionTask?.value
        while let task = skills.operationTask { await task.value }
        library.load(); await library.loadTask?.value
        panel.projects.load(); await panel.projects.operationTask?.value
        #expect(library.entries().count == 2 && library.pendingCount == 2)
        #expect(panel.projects.selected?.sessions.count == 2)
        panel.agentWorkspace.selectAgent("codex")
        configuration.model = "Unsaved model"
        library.select(sessions[1].key)
        library.draft.notes = "Keep my session draft"
        let draft = library.draft
        panel.agentSelection.setManaged("codex", false)
        while let task = skills.operationTask { await task.value }
        #expect(panel.agentWorkspace.availableAgents.map(\.id) == ["claude"])
        #expect(skills.deploymentTargets.map(\.id) == ["claude"])
        #expect(library.entries().map(\.session.agent) == [.claude])
        #expect(library.pendingCount == 1)
        #expect(panel.projects.selected?.sessions.map(\.session.agent) == [.claude])
        #expect(library.selected == nil && library.draft == draft && library.dirty)
        #expect(configuration.dirty && configuration.model == "Unsaved model")
        configuration.save()
        #expect(try String(contentsOf: configFile, encoding: .utf8) == originalConfig)
        let target = try #require(rules.targets.first { $0.id == "codex" })
        rules.toggle(target, on: true); rules.write(target)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        skills.previewUndo(); await skills.operationTask?.value
        #expect(skills.plan == nil && skills.errorMessage != nil)
        #expect(try await skillStore.load().deployments.count == 1)
        panel.agentSelection.selectNone()
        #expect(library.entries().isEmpty && library.pendingCount == 0)
        #expect(panel.projects.selected?.sessions.isEmpty == true) // Manual project remains.
        #expect(try await catalog.load().sessions.count == 2)
        panel.agentSelection.setManaged("codex", true)
        #expect(library.selected?.id == sessions[1].key && library.draft == draft)
    }

    @Test func historyWaitsForSelectionAndImportsOnlySelectedAgents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = [Session(id: "a", agent: .claude, cwd: root.path, startedAt: Date()),
                       Session(id: "b", agent: .codex, cwd: root.path, startedAt: Date())]
        let catalog = SessionCatalog(url: root.appendingPathComponent("sessions.json"))
        let library = SessionLibraryModel(catalog: catalog, historyScanner: { _ in entries })
        library.managedAgentIDs = []
        library.open()
        #expect(library.importTask == nil)
        library.managedAgentIDs = ["claude"]
        await library.importTask?.value
        #expect(try await catalog.load().sessions.map(\.agent) == [.claude])
    }

    @Test func selectedButMissingAgentCanKeepHistoryWithoutBecomingAWriteTarget() async {
        let suite = "missing-agent-scope-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.managedAgentIDs = ["codex"]
        let scope = AgentSelectionModel(settings: settings, detect: { [] })
        scope.refresh(); await scope.refreshTask?.value
        #expect(scope.state.managedIDs == ["codex"])
        #expect(scope.state.available.isEmpty)
    }
}

private final class SelectionDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String>
    init(_ ids: Set<String>) { self.ids = ids }
    func set(_ value: Set<String>) { lock.lock(); defer { lock.unlock() }; ids = value }
    func detect() -> [AgentDescriptor] { lock.lock(); defer { lock.unlock() }; return AgentRegistry.all.filter { ids.contains($0.id) } }
}
