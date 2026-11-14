import Foundation
import Testing
import MusterCore
@testable import Muster

@Suite @MainActor struct AgentWorkspaceTests {
    @Test func navigationMigrationPreservesOrderAndLastSectionExactlyOnce() {
        let suite = "agent-nav-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Configuration", forKey: "MusterLastTab")
        defaults.set(["Projects", "Instructions", "Sessions", "Configuration", "Environment"], forKey: "MusterTabOrder")
        AgentNavigation.migrate(defaults)
        #expect(defaults.string(forKey: "MusterLastTab") == "Agent")
        #expect(defaults.string(forKey: "MusterAgentSection") == "configuration")
        #expect(defaults.stringArray(forKey: "MusterTabOrder") == ["Projects", "Agent", "Sessions", "Environment"])
        defaults.set("skills", forKey: "MusterAgentSection")
        AgentNavigation.migrate(defaults)
        #expect(defaults.string(forKey: "MusterAgentSection") == "skills")
    }

    @Test func skillDraftSurvivesReopenAndRequiresChoiceBeforeSwitching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SkillLibrary(root: root)
        _ = try await library.create(name: "one", description: "One")
        _ = try await library.create(name: "two", description: "Two")
        let model = SkillsModel(library: library, targets: [])
        model.load()
        await model.operationTask?.value
        let first = try #require(model.selected)
        let second = try #require(model.snapshot.skills.first { $0.id != first.id })
        model.draft += "\nUnpublished edits"
        let text = model.draft
        model.select(second.id)
        #expect(model.confirmsSelection)
        #expect(model.selectedID == first.id)
        model.resolveSelection(save: true)
        await model.operationTask?.value
        #expect(model.selectedID == second.id)
        model.select(first.id)
        await model.operationTask?.value
        #expect(model.draft == text && model.dirty && !model.unsaved)
        let reopened = SkillsModel(library: library, targets: [])
        reopened.load()
        await reopened.operationTask?.value
        #expect(reopened.draft == text)
        reopened.publish()
        await reopened.operationTask?.value
        #expect(!reopened.dirty)
        #expect(try await library.content(first.id).text == text)
    }

    @Test func changingAgentDoesNotSilentlyDiscardConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "agent-choice-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let file = root.appendingPathComponent(".pi/agent/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"defaultProvider":"p","defaultModel":"old"}"#.write(to: file, atomically: true, encoding: .utf8)
        let config = ConfigurationModel(store: AgentConfigurationStore(backupDirectory: root.appendingPathComponent("backups")),
            presetStore: ConfigurationPresetStore(url: root.appendingPathComponent("presets.json")),
            detectTargets: { AgentConfiguration.detect(home: root.path, environment: [:]) })
        let rules = InstructionsModel(sync: InstructionSync(paths: InstructionPaths(support: root.appendingPathComponent("rules").path)), detectTargets: { [] })
        let skills = SkillsModel(library: SkillLibrary(root: root.appendingPathComponent("skills")), targets: [])
        let workspace = AgentWorkspaceModel(instructions: rules, configuration: config, skills: skills, defaults: defaults,
            detectInstalledAgents: { AgentRegistry.all.filter { ["pi", "claude"].contains($0.id) } })
        workspace.load()
        await workspace.detectionTask?.value
        await skills.operationTask?.value
        workspace.selectAgent("pi")
        config.model = "unsaved"
        workspace.selectAgent("claude")
        #expect(workspace.confirmsAgentChange)
        #expect(workspace.agentID == "pi" && config.model == "unsaved")
        workspace.resolveAgentChange(save: true)
        #expect(workspace.agentID == "claude" && !config.dirty)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("unsaved"))
    }

    @Test func scopedRuleApplicationWritesOnlyVisibleTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = InstructionSync(paths: InstructionPaths(support: root.appendingPathComponent("support").path))
        try sync.saveText("Shared rule", setID: InstructionSet.defaultID)
        let first = InstructionTarget(id: "claude", name: "Claude", path: root.appendingPathComponent("a.md").path, installed: true)
        let second = InstructionTarget(id: "codex", name: "Codex", path: root.appendingPathComponent("b.md").path, installed: true)
        let model = InstructionsModel(sync: sync, detectTargets: { [first, second] })
        model.loadIfNeeded()
        model.toggle(first, on: true); model.toggle(second, on: true)
        model.writeAll(targetIDs: [first.id])
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(model.isPending(second.id))
    }
}

extension AgentWorkspaceTests {
    @Test func refreshingPublishedContentKeepsPendingTargetsAndUnsavedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SkillLibrary(root: root.appendingPathComponent("library"))
        var skill = try #require(try await library.create(name: "review", description: "Review").skills.first)
        let target = SkillTarget(id: "claude", name: "Claude", directory: root.appendingPathComponent("skills").path)
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        model.setEnabled(target, true)
        let updatedText = model.publishedText + "\nExternal published change."
        skill = try #require(try await library.publish(skill.id, expectedRevision: skill.revision, text: updatedText).skills.first)
        model.load(force: true); await model.operationTask?.value
        #expect(model.draft == updatedText)
        #expect(model.desired[target.id] == .symlink)
        model.draft += "\nUnsaved local work."
        let localText = model.draft
        _ = try await library.publish(skill.id, expectedRevision: skill.revision, text: updatedText + "\nAnother external change.")
        model.load(force: true); await model.operationTask?.value
        #expect(model.draft == localText)
        #expect(!model.canPublish)
    }
}

extension AgentWorkspaceTests {
    @Test func agentPickerAndSkillTargetsUseDetectedAgentsAndResetAStaleSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "agent-picker-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("gemini", forKey: "MusterSelectedAgent")
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let rules = InstructionsModel(sync: InstructionSync(paths: InstructionPaths(support: root.appendingPathComponent("rules").path)), detectTargets: { [] })
        let config = ConfigurationModel(presetStore: ConfigurationPresetStore(url: root.appendingPathComponent("presets.json")), detectTargets: { [] })
        let skills = SkillsModel(library: SkillLibrary(root: root.appendingPathComponent("library")), targets: AgentRegistry.skillTargets(home: root.path, environment: [:]))
        let workspace = AgentWorkspaceModel(instructions: rules, configuration: config, skills: skills, defaults: defaults,
            detectInstalledAgents: { AgentRegistry.all.filter { $0.id == "claude" || $0.id == "warp" } })
        workspace.load()
        await workspace.detectionTask?.value
        await skills.operationTask?.value
        #expect(workspace.availableAgents.map(\.id) == ["claude", "warp"])
        #expect(skills.deploymentTargets.map(\.id) == ["claude"])
        #expect(workspace.agentID == "all")
        workspace.selectAgent("gemini")
        #expect(workspace.agentID == "all")
        workspace.selectAgent("claude")
        #expect(workspace.agentID == "claude")
    }

    @Test func hiddenUninstalledTargetsAreNeitherUpdatedNorRemovedByDeployment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SkillLibrary(root: root.appendingPathComponent("library"))
        let targets = AgentRegistry.skillTargets(home: root.path, environment: [:]).filter { ["claude", "pi"].contains($0.id) }
        let skill = try #require(try await library.create(name: "review", description: "Review").skills.first)
        _ = try await library.apply(library.plan(skill.id, desired: ["claude": .copy, "pi": .copy], targets: targets))
        let oldText = try await library.content(skill.id).text
        _ = try await library.publish(skill.id, expectedRevision: skill.revision, text: oldText + "\nNew version.")
        let model = SkillsModel(library: library, targets: targets)
        model.restrictToAgents(["claude"])
        model.load(); await model.operationTask?.value
        model.preview(); await model.operationTask?.value
        #expect(model.plan?.items.map { $0.after?.targetID } == ["claude"])
        model.apply(); await model.operationTask?.value
        let snapshot = try await library.load()
        #expect(snapshot.deployments.first { $0.targetID == "pi" }?.revision == skill.revision)
        let path = try #require(targets.first { $0.id == "pi" }?.directory)
        #expect(try String(contentsOfFile: path + "/review/SKILL.md", encoding: .utf8) == oldText)
    }
}

extension AgentWorkspaceTests {
    @Test func uninstallRefreshKeepsConfigurationAndSkillDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "agent-uninstall-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let file = root.appendingPathComponent(".pi/agent/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"defaultProvider":"p","defaultModel":"old"}"#.write(to: file, atomically: true, encoding: .utf8)
        let config = ConfigurationModel(presetStore: ConfigurationPresetStore(url: root.appendingPathComponent("presets.json")),
            detectTargets: { AgentConfiguration.detect(home: root.path, environment: [:]) })
        let rules = InstructionsModel(sync: InstructionSync(paths: InstructionPaths(support: root.appendingPathComponent("rules").path)), detectTargets: { [] })
        let library = SkillLibrary(root: root.appendingPathComponent("library"))
        _ = try await library.create(name: "review", description: "Review")
        let skills = SkillsModel(library: library, targets: AgentRegistry.skillTargets(home: root.path, environment: [:]))
        let presence = AgentPresenceFixture()
        let workspace = AgentWorkspaceModel(instructions: rules, configuration: config, skills: skills, defaults: defaults,
            detectInstalledAgents: { presence.agents() })
        workspace.load(); await workspace.detectionTask?.value; await skills.operationTask?.value
        workspace.selectAgent("pi")
        config.model = "Unsaved model"
        skills.draft += "\nUnsaved skill draft"
        let draft = skills.draft
        presence.uninstall()
        workspace.refreshAgents(); await workspace.detectionTask?.value; await skills.operationTask?.value
        #expect(workspace.availableAgents.isEmpty)
        #expect(workspace.agentID == "all")
        #expect(config.model == "Unsaved model" && config.dirty)
        #expect(skills.draft == draft && skills.unsaved)
        #expect(skills.deploymentTargets.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("old"))
    }
}

private final class AgentPresenceFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var present = true
    func agents() -> [AgentDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return present ? AgentRegistry.all.filter { $0.id == "pi" } : []
    }
    func uninstall() { lock.lock(); defer { lock.unlock() }; present = false }
}
