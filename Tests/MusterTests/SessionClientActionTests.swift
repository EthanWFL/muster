import Foundation
import Testing
import MusterCore
@testable import Muster

@Suite @MainActor struct SessionClientActionTests {
    @Test func activatesOnlyTheKnownRunningClientAndDoesNotFallbackWhenItIsGone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "client-action-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.managedAgentIDs = ["pi"]
        let library = SessionLibraryModel(catalog: SessionCatalog(url: root.appendingPathComponent("sessions.json")), historyScanner: { _ in [] })
        let model = PanelModel(library: library, projectStore: ProjectStore(url: root.appendingPathComponent("projects.json")),
                               projectDefaults: defaults, detectInstalledAgents: { [] }, settingsStore: settings)
        var session = Session(id: "live", agent: .pi, cwd: "/tmp", pid: 42, startedAt: Date(),
                              client: SessionClient(name: "Warp", bundlePath: "/Applications/Warp.app"))
        var activated: [String] = []
        model.openClient(session) { client in activated.append(client.name); return true }
        #expect(activated == ["Warp"] && model.notice == nil)
        model.openClient(session) { client in activated.append(client.name); return false }
        #expect(activated == ["Warp", "Warp"])
        #expect(model.notice?.contains("Warp") == true)
        session.isProcessAlive = false
        model.openClient(session) { _ in Issue.record("Exited sessions must not activate applications"); return false }
        session.isProcessAlive = true
        session.client = nil
        model.openClient(session) { _ in Issue.record("Unknown clients must not activate applications"); return false }
        session.client = SessionClient(name: "Warp", bundlePath: "/Applications/Warp.app")
        model.agentSelection.selectNone()
        model.openClient(session) { _ in Issue.record("Unmanaged sessions must not activate applications"); return false }
        #expect(activated.count == 2)
    }
}
