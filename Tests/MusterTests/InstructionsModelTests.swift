import Foundation
import Testing
import MusterCore
@testable import Muster

@Suite @MainActor struct InstructionsModelTests {
    @Test func applyingAnOutdatedPreviewPreservesExternalEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = InstructionSync(paths: InstructionPaths(support: root.path + "/support"))
        try sync.saveText("new rules", setID: InstructionSet.defaultID)
        let target = InstructionTarget(id: "claude", name: "Claude", path: root.path + "/CLAUDE.md", installed: true)
        try "original".write(toFile: target.path, atomically: true, encoding: .utf8)
        try sync.save(InstructionSyncState(enabled: [target.id: true]))
        let model = InstructionsModel(sync: sync, detectTargets: { [target] })
        model.loadIfNeeded()
        try "external edit".write(toFile: target.path, atomically: true, encoding: .utf8)
        model.write(target)
        #expect(model.errorMessage != nil)
        #expect(try String(contentsOfFile: target.path, encoding: .utf8) == "external edit")
        // A refreshed preview preserves the external content when explicitly applied again.
        model.write(target)
        let result = try String(contentsOfFile: target.path, encoding: .utf8)
        #expect(result.contains("external edit"))
        #expect(InstructionBlock.split(result)?.block == "new rules")
        #expect(model.errorMessage == nil)
    }

    @Test func applyingCannotUseAPreviewFromBeforeUnsavedEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = InstructionSync(paths: InstructionPaths(support: root.path + "/support"))
        try sync.saveText("old draft", setID: InstructionSet.defaultID)
        let target = InstructionTarget(id: "claude", name: "Claude", path: root.path + "/CLAUDE.md", installed: true)
        try sync.save(InstructionSyncState(enabled: [target.id: true]))
        let model = InstructionsModel(sync: sync, detectTargets: { [target] })
        model.loadIfNeeded()
        model.draft = "new draft"
        model.writeAll()
        #expect(!FileManager.default.fileExists(atPath: target.path))
        model.saveNow()
        model.writeAll()
        #expect(InstructionBlock.split(try String(contentsOfFile: target.path, encoding: .utf8))?.block == "new draft")
    }

    @Test func browsingAndSavingDraftNeverWritesAgentFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = InstructionSync(paths: InstructionPaths(support: root.path + "/support"))
        try sync.saveText("original", setID: InstructionSet.defaultID)
        let alternate = try sync.createSet(named: "Review")
        try sync.saveText("review", setID: alternate.id)
        let target = InstructionTarget(id: "claude", name: "Claude", path: root.path + "/CLAUDE.md", installed: true)
        let original = InstructionBlock.withBlock("My own rules", "original")
        try original.write(toFile: target.path, atomically: true, encoding: .utf8)
        var state = InstructionSyncState()
        state.sets = [alternate]
        state.enabled[target.id] = true
        state.writtenHash[target.id] = InstructionBlock.hash("original")
        try sync.save(state)
        let model = InstructionsModel(sync: sync, detectTargets: { [target] })
        model.loadIfNeeded()
        model.selectSet(alternate.id)
        #expect(try String(contentsOfFile: target.path, encoding: .utf8) == original)
        model.draft = "edited review"
        model.saveNow()
        #expect(try String(contentsOfFile: target.path, encoding: .utf8) == original)
        model.toggle(target, on: false)
        #expect(try String(contentsOfFile: target.path, encoding: .utf8) == original)
        model.toggle(target, on: true)
        #expect(try String(contentsOfFile: target.path, encoding: .utf8) == original)
        model.writeAll()
        #expect(InstructionBlock.split(try String(contentsOfFile: target.path, encoding: .utf8))?.block == "edited review")
        model.toggle(target, on: false)
        model.writeAll()
        #expect(InstructionBlock.split(try String(contentsOfFile: target.path, encoding: .utf8)) == nil)
        #expect(try String(contentsOfFile: target.path, encoding: .utf8).contains("My own rules"))
    }
}
