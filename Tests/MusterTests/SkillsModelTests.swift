import Foundation
import Testing
import MusterCore
@testable import Muster

@Suite @MainActor struct SkillsModelTests {
    private func makeLibrary() async throws -> (SkillLibrary, SkillTarget, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-model-" + UUID().uuidString)
        let library = SkillLibrary(root: root.appendingPathComponent("library"))
        _ = try await library.create(name: "one", description: "One")
        _ = try await library.create(name: "two", description: "Two")
        let target = SkillTarget(id: "claude", name: "Claude", directory: root.appendingPathComponent("claude-skills").path)
        return (library, target, root)
    }

    @Test func markingASecondSkillKeepsTheEditorOnWhatIsBeingRead() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        let first = try #require(model.selected)
        let second = try #require(model.snapshot.skills.first { $0.id != first.id })

        model.mark(second.id); await model.operationTask?.value
        #expect(model.selectedID == first.id)
        #expect(model.markedIDs == [first.id, second.id])
        #expect(model.isBatch)
        // Two marks, one pending change: the bar must not claim two skills changed.
        model.setEnabled(target, true)
        #expect(model.batchDirty && model.pendingItems == 2)
        model.clearMarks()
        #expect(!model.isBatch && model.markedIDs == [first.id])
    }

    @Test func batchPreviewDeploysEveryMarkedSkillInOnePlan() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        model.markAll()
        model.setEnabled(target, true)
        model.preview(); await model.operationTask?.value
        let plan = try #require(model.plan)
        #expect(plan.items.count == 2)
        #expect(plan.skillIDs.count == 2)
        model.apply(); await model.operationTask?.value
        #expect(try await library.load().deployments.count == 2)
        #expect(!model.batchDirty)
    }

    @Test func existingAgentFolderNeedsAnExplicitAdoptionBeforeApplying() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let occupied = URL(fileURLWithPath: target.directory).appendingPathComponent("one")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try "---\nname: one\ndescription: Hand written\n---\nMine.".write(
            to: occupied.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        model.setEnabled(target, true)
        model.preview(); await model.operationTask?.value
        let blocked = try #require(model.plan)
        #expect(!blocked.canApply && blocked.adoptablePaths == [occupied.path])

        model.adoptAll(); await model.operationTask?.value
        let plan = try #require(model.plan)
        #expect(plan.canApply && plan.adoptions == 1)
        model.apply(); await model.operationTask?.value
        #expect(model.errorMessage == nil)
        #expect(try String(contentsOf: occupied.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("# one"))
    }

    @Test func editingASupportingFileCountsAsAnUnsavedDraftAndSurvivesReopen() async throws {
        let (library, _, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SkillsModel(library: library, targets: [])
        model.load(); await model.operationTask?.value
        let id = try #require(model.selectedID)
        model.addFile(path: "references/guide.md"); await model.operationTask?.value
        #expect(model.errorMessage == nil)
        model.setFileText("references/guide.md", "Guidance")
        #expect(model.unsaved && model.dirty)
        model.saveDraft(); await model.operationTask?.value
        #expect(!model.unsaved && model.dirty)
        model.publish(); await model.operationTask?.value
        #expect(!model.dirty)
        #expect(try await library.content(id).texts["references/guide.md"] == "Guidance")
    }

    @Test func aSkillThatIsStillDeployedCannotBeRemovedOrRenamed() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        let skill = try #require(model.selected)
        model.setEnabled(target, true)
        model.preview(); await model.operationTask?.value
        model.apply(); await model.operationTask?.value
        #expect(!model.canRemove)
        model.removeSelected(); await model.operationTask?.value
        #expect(model.errorMessage != nil)
        #expect(model.snapshot.skills.contains { $0.id == skill.id })

        // Turning the deployment off makes both edits available again.
        model.setEnabled(target, false)
        model.preview(); await model.operationTask?.value
        model.apply(); await model.operationTask?.value
        #expect(model.canRemove)
        model.renameSelected(to: "renamed"); await model.operationTask?.value
        #expect(model.errorMessage == nil)
        #expect(model.snapshot.skills.contains { $0.id == skill.id && $0.name == "renamed" })
        model.removeSelected(); await model.operationTask?.value
        #expect(!model.snapshot.skills.contains { $0.id == skill.id })
    }

    @Test func aDisplacedAgentFolderIsPutBackWhenItsDeploymentIsTurnedOff() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let occupied = URL(fileURLWithPath: target.directory).appendingPathComponent("one")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try "---\nname: one\ndescription: Hand written\n---\nMine.".write(
            to: occupied.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        model.setEnabled(target, true)
        model.preview(); await model.operationTask?.value
        model.adoptAll(); await model.operationTask?.value
        model.apply(); await model.operationTask?.value
        #expect(try String(contentsOf: occupied.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("# one"))

        model.setEnabled(target, false)
        model.preview(); await model.operationTask?.value
        model.apply(); await model.operationTask?.value
        #expect(try String(contentsOf: occupied.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("Mine."))
    }

    @Test func anEmptyDeploymentAreaExplainsWhichAgentToEnable() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SkillsModel(library: library, targets: [target])
        model.restrictToAgents([])
        #expect(model.deploymentTargets.isEmpty)
        #expect(model.scopedOutTargets.map(\.id) == ["claude"])
        model.restrictToAgents(["claude"])
        #expect(model.deploymentTargets.map(\.id) == ["claude"])
        #expect(model.scopedOutTargets.isEmpty)
    }
}
