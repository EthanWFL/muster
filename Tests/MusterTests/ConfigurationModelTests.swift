import Foundation
import Testing
import MusterCore
@testable import Muster

@Suite @MainActor struct ConfigurationModelTests {
    @Test func savingAndLoadingPresetsDoesNotWriteUntilExplicitSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".pi/agent/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #"{"defaultProvider":"p","defaultModel":"old","other":true}"#
        try original.write(to: file, atomically: true, encoding: .utf8)
        let store = ConfigurationPresetStore(url: root.appendingPathComponent("presets.json"))
        let model = ConfigurationModel(store: AgentConfigurationStore(backupDirectory: root.appendingPathComponent("backups")),
            presetStore: store, detectTargets: { AgentConfiguration.detect(home: root.path, environment: [:]) })
        model.loadIfNeeded()
        model.model = "new"
        model.presetName = "Work"
        model.savePreset()
        let preset = try #require(model.presets.first)
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        model.reload()
        model.usePreset(preset)
        #expect(model.dirty)
        #expect(model.model == "new")
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        // A second selection never discards an unsaved form.
        model.usePreset(ConfigurationPreset(name: "Other", agentID: "pi", provider: "p", model: "discard"))
        #expect(model.model == "new")
        model.save()
        #expect(!model.dirty)
        #expect(model.canRestore)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\"defaultModel\":\"new\""))
        model.restore()
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }
}
