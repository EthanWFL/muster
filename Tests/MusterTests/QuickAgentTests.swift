import Foundation
import Testing
import MusterCore
@testable import Muster

@Suite @MainActor struct QuickAgentTests {
    @Test func defaultsToRulesAndRemembersQuickTabIndependentlyOfTheWindow() async throws {
        let f = try QuickAgentFixture()
        defer { f.cleanup() }
        await f.load()
        let model = f.workspace
        #expect(model.quickSection == .rules && model.quickRulesAgentID == "all")
        model.selectSection(.skills)
        model.selectAgent("codex")
        model.selectQuickSection(.configuration)
        #expect(model.section == .skills)
        #expect(f.configuration.selected?.id == "codex")
        model.selectQuickConfigurationAgent("pi")
        model.openQuickInWindow()
        #expect(model.section == .configuration && model.agentID == "pi")
        #expect(f.configuration.selected?.id == "pi")
        model.openQuickInWindow(skills: true)
        #expect(model.section == .skills && model.quickSection == .configuration)
        let restored = AgentWorkspaceModel(instructions: f.rules, configuration: f.configuration, skills: f.skills,
            defaults: f.defaults, detectInstalledAgents: { AgentRegistry.all.filter { ["codex", "pi"].contains($0.id) } })
        #expect(restored.quickSection == .configuration)
        #expect(restored.section == .skills)
    }

    @Test func rememberedConfigurationAndRuleFilterAreIndependentAndScoped() async throws {
        let f = try QuickAgentFixture()
        defer { f.cleanup() }
        f.defaults.set("pi", forKey: "MusterQuickConfigurationAgent")
        await f.load()
        f.workspace.selectQuickRulesAgent("codex")
        f.workspace.selectQuickSection(.configuration)
        #expect(f.configuration.selected?.id == "pi")
        f.configuration.model = "Unsaved Pi draft"
        f.workspace.selectQuickSection(.rules)
        f.workspace.selectQuickRulesAgent("all")
        #expect(f.configuration.model == "Unsaved Pi draft" && f.configuration.dirty)
        #expect(!f.workspace.confirmsAgentChange)
        f.workspace.openQuickInWindow()
        #expect(f.workspace.section == .rules && f.workspace.agentID == "all")
        #expect(f.rules.editorFocusRequest > 0)
        f.workspace.selectQuickSection(.configuration)
        #expect(f.configuration.selected?.id == "pi")
        #expect(f.configuration.model == "Unsaved Pi draft")
    }

    @Test func changingQuickConfigurationRequiresExplicitSaveOrDiscard() async throws {
        let f = try QuickAgentFixture()
        defer { f.cleanup() }
        await f.load()
        f.workspace.selectQuickSection(.configuration)
        #expect(f.configuration.selected?.id == "codex")
        f.configuration.model = "next-model"
        f.workspace.selectQuickConfigurationAgent("pi")
        #expect(f.workspace.confirmsAgentChange && f.workspace.agentChangeInQuickPanel)
        #expect(f.configuration.selected?.id == "codex")
        f.workspace.cancelAgentChange()
        #expect(f.configuration.dirty && f.configuration.model == "next-model")
        f.workspace.selectQuickConfigurationAgent("pi")
        f.workspace.resolveAgentChange(save: true)
        #expect(f.configuration.selected?.id == "pi")
        #expect(try String(contentsOf: f.root.appendingPathComponent(".codex/config.toml"), encoding: .utf8).contains("next-model"))
        f.configuration.model = "Discard me"
        f.workspace.selectQuickConfigurationAgent("codex")
        f.workspace.resolveAgentChange(save: false)
        #expect(f.configuration.selected?.id == "codex")
        #expect(try String(contentsOf: f.root.appendingPathComponent(".pi/agent/settings.json"), encoding: .utf8).contains("pi-old"))
        f.configuration.model = "Window draft"
        f.workspace.selectAgent("pi")
        #expect(!f.workspace.agentChangeInQuickPanel)
        f.workspace.resolveAgentChange(save: false)
        #expect(f.workspace.agentID == "pi" && f.configuration.selected?.id == "pi")
    }

    @Test func scopeChangeKeepsAHiddenConfigurationDraftUntilResolved() async throws {
        let f = try QuickAgentFixture()
        defer { f.cleanup() }
        await f.load()
        f.workspace.selectQuickSection(.configuration)
        f.configuration.model = "Keep draft"
        f.workspace.selection.setManaged("codex", false)
        f.workspace.prepareQuickConfiguration()
        #expect(f.configuration.selected?.id == "codex" && f.configuration.dirty)
        #expect(f.workspace.quickConfigurationTargets.map(\.id) == ["pi"])
        f.workspace.selectQuickConfigurationAgent("pi")
        #expect(f.workspace.confirmsAgentChange && !f.configuration.canWrite)
        f.workspace.cancelAgentChange()
        f.workspace.selection.setManaged("codex", true)
        #expect(f.configuration.model == "Keep draft" && f.configuration.canWrite)
    }
}

@MainActor private final class QuickAgentFixture {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let rules: InstructionsModel
    let configuration: ConfigurationModel
    let skills: SkillsModel
    let workspace: AgentWorkspaceModel
    init() throws {
        suite = "muster-quick-agent-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        for directory in [".codex", ".pi/agent"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try "model = \"codex-old\"\n".write(to: root.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        try #"{"defaultProvider":"p","defaultModel":"pi-old"}"#.write(to: root.appendingPathComponent(".pi/agent/settings.json"), atomically: true, encoding: .utf8)
        let folder = root
        rules = InstructionsModel(sync: InstructionSync(paths: InstructionPaths(support: root.appendingPathComponent("rules").path)), detectTargets: { [] })
        configuration = ConfigurationModel(store: AgentConfigurationStore(backupDirectory: root.appendingPathComponent("backups")),
            presetStore: ConfigurationPresetStore(url: root.appendingPathComponent("presets.json")),
            detectTargets: { AgentConfiguration.detect(home: folder.path, environment: [:]) })
        skills = SkillsModel(library: SkillLibrary(root: root.appendingPathComponent("skills")), targets: [])
        workspace = AgentWorkspaceModel(instructions: rules, configuration: configuration, skills: skills, defaults: defaults,
            detectInstalledAgents: { AgentRegistry.all.filter { ["codex", "pi"].contains($0.id) } })
    }
    func load() async {
        workspace.load(syncWindowSelection: false)
        await workspace.detectionTask?.value
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
