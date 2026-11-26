import Foundation
import Testing
import MusterCore
@testable import Muster

@Suite(.serialized) @MainActor struct NavigationTests {
    @Test func destinationsMapBackToNavigationState() {
        let model = PanelModel(detectInstalledAgents: { [] })
        model.select(.workspace(.projects))
        #expect(model.destination == .workspace(.projects))
        #expect(!model.showsSettings)

        model.select(.chat)
        #expect(model.destination == .chat)
        #expect(model.managementPage == .chat)

        model.showSettings(.about)
        #expect(model.destination == .settings)
        #expect(model.settingsSection == .about)

        model.select(.wheel)
        #expect(model.destination == .wheel)
        model.select(.workspace(.sessions))
        #expect(model.destination == .workspace(.sessions))
        #expect(!model.showsSettings)
    }

    @Test func chatSitsAfterSessionsInTheWorkspaceTable() {
        let model = PanelModel(detectInstalledAgents: { [] })
        let destinations = model.workspaceDestinations
        let sessions = try! #require(destinations.firstIndex(of: .workspace(.sessions)))
        #expect(destinations[sessions + 1] == .chat)
        #expect(Set(destinations).count == destinations.count)
    }

    @Test func unsavedAreasReportRuleAndSkillDrafts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "navigation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let rules = InstructionsModel(
            sync: InstructionSync(paths: InstructionPaths(support: root.appendingPathComponent("rules").path)),
            detectTargets: { [] })
        let skills = SkillsModel(library: SkillLibrary(root: root.appendingPathComponent("skills")), targets: [])
        let model = PanelModel(projectDefaults: defaults, instructionsModel: rules, skillsModel: skills,
                               detectInstalledAgents: { [] }, settingsStore: SettingsStore(defaults: defaults))

        #expect(model.unsavedAreas.isEmpty)
        model.instructions.draft = "pending rule edit"
        #expect(model.unsavedAreas.contains(L10n.t("Instructions")))
        model.agentWorkspace.skills.draft = "pending skill edit"
        #expect(model.unsavedAreas.contains(L10n.t("Skill draft")))
    }
}
