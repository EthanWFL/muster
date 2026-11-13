import Foundation
import Testing
@testable import MusterCore

@Suite struct ConfigurationPresetTests {
    @Test func roundTripsAndSeparatesAgentNamesWithPrivatePermissions() throws {
        let tree = try TempTree()
        let store = ConfigurationPresetStore(url: URL(fileURLWithPath: tree.path("presets.json")))
        let pi = ConfigurationPreset(name: "Work", agentID: "pi", provider: "p", model: "model")
        let codex = ConfigurationPreset(name: "Work", agentID: "codex", provider: "p", model: "model")
        try store.save(pi)
        try store.save(codex)
        #expect(Set(try store.load()) == [pi, codex])
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        try store.remove(pi.id)
        #expect(try store.load() == [codex])
    }

    @Test func rejectsDuplicateNamesInvalidValuesAndUnsupportedAgents() throws {
        let tree = try TempTree()
        let store = ConfigurationPresetStore(url: URL(fileURLWithPath: tree.path("presets.json")))
        let preset = ConfigurationPreset(name: "Work", agentID: "pi", provider: "p", model: "model")
        try store.save(preset)
        #expect(throws: PresetError.duplicate) {
            try store.save(ConfigurationPreset(name: "work", agentID: "pi", provider: "p", model: "new"))
        }
        for name in ["", " leading", "two\nlines"] {
            #expect(throws: PresetError.invalid) {
                try store.save(ConfigurationPreset(name: name, agentID: "pi", provider: "p", model: "model"))
            }
        }
        #expect(throws: PresetError.unsupported) {
            try store.save(ConfigurationPreset(name: "Work", agentID: "claude", provider: "p", model: "model"))
        }
        #expect(try store.load() == [preset])
    }

    @Test func damagedStoreIsNotOverwrittenBySaveOrDelete() throws {
        let tree = try TempTree()
        try tree.write("presets.json", "{damaged}")
        let store = ConfigurationPresetStore(url: URL(fileURLWithPath: tree.path("presets.json")))
        #expect(throws: (any Error).self) {
            try store.save(ConfigurationPreset(name: "Work", agentID: "pi", provider: "p", model: "model"))
        }
        #expect(throws: (any Error).self) { try store.remove(UUID()) }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "{damaged}")
    }
}
