import Foundation
import Testing
@testable import MusterCore

@Suite struct SkillDeploymentConflictTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-conflict-" + UUID().uuidString)
        var library: SkillLibrary { SkillLibrary(root: root.appendingPathComponent("library")) }
        var target: SkillTarget { SkillTarget(id: "claude", name: "Claude", directory: root.appendingPathComponent("agent").path) }
        var destination: URL { URL(fileURLWithPath: target.directory).appendingPathComponent("review") }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func create(_ location: URL, text: String = "Original") throws {
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
            try (SkillDocument.template(name: "review", description: text) + text).write(
                to: location.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        func deploy() async throws -> SkillRecord {
            let skill = try #require(try await library.create(name: "review", description: "Library").skills.first)
            _ = try await library.apply(library.plan(skill.id, desired: [target.id: .symlink], targets: [target]))
            return skill
        }
        func inspection() async throws -> SkillDeploymentInspection {
            try #require(try await library.load().deploymentInspections.values.first)
        }
    }

    @Test func missingEntryCanBeForgottenWithoutRecreatingItAndCannotUndoStaleHistory() async throws {
        let f = Fixture(); defer { f.cleanup() }
        _ = try await f.deploy()
        try FileManager.default.removeItem(at: f.destination)
        let inspection = try await f.inspection()
        #expect(inspection.status == .missing)
        let result = try await f.library.releaseDeployment(inspection)
        #expect(result.deployments.isEmpty && !result.canUndo)
        #expect(!FileManager.default.fileExists(atPath: f.destination.path))
    }

    @Test func foreignLinkReleaseDoesNotTouchTheLinkOrItsContents() async throws {
        let f = Fixture(); defer { f.cleanup() }
        _ = try await f.deploy()
        let foreign = f.root.appendingPathComponent("magpie/review")
        try f.create(foreign)
        try FileManager.default.removeItem(at: f.destination)
        try FileManager.default.createSymbolicLink(at: f.destination, withDestinationURL: foreign)
        let inspection = try await f.inspection()
        #expect(inspection.status == .changed)
        #expect(try await f.library.discover(targets: [f.target]).first?.managed == false)
        _ = try await f.library.releaseDeployment(inspection)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.destination.path) == foreign.path)
        #expect(try String(contentsOf: foreign.appendingPathComponent("SKILL.md"), encoding: .utf8).hasSuffix("Original"))
    }

    @Test func staleReviewAndHealthyDeploymentCannotBeReleased() async throws {
        let f = Fixture(); defer { f.cleanup() }
        _ = try await f.deploy()
        let active = try await f.inspection()
        await #expect(throws: SkillError.changed) { try await f.library.releaseDeployment(active) }
        try FileManager.default.removeItem(at: f.destination)
        let missing = try await f.inspection()
        try f.create(f.destination)
        await #expect(throws: SkillError.changed) { try await f.library.releaseDeployment(missing) }
        #expect(try await f.library.load().deployments.count == 1)
    }

    @Test func redeployRequiresAdoptionAndUndoReturnsTheForeignLink() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let skill = try await f.deploy()
        let foreign = f.root.appendingPathComponent("foreign")
        try f.create(foreign)
        try FileManager.default.removeItem(at: f.destination)
        try FileManager.default.createSymbolicLink(at: f.destination, withDestinationURL: foreign)
        _ = try await f.library.releaseDeployment(f.inspection())
        let plan = try await f.library.plan(skill.id, desired: [f.target.id: .symlink], targets: [f.target])
        #expect(!plan.canApply && plan.adoptablePaths == [f.destination.path])
        _ = try await f.library.apply(f.library.plan(skill.id, desired: [f.target.id: .symlink],
            targets: [f.target], adopting: [f.destination.path]))
        #expect(try await f.inspection().status == .active)
        _ = try await f.library.undo(f.library.undoPreview())
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.destination.path) == foreign.path)
        #expect(try await f.library.load().deployments.isEmpty)
    }

    @Test func releasedAdoptionBackupsSurviveLaterDeploymentsAndPruning() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.create(name: "review", description: "Library").skills.first)
        try f.create(f.destination, text: "Original before Muster")
        let adoption = try await f.library.plan(skill.id, desired: [f.target.id: .symlink], targets: [f.target], adopting: [f.destination.path])
        let originalBackup = try #require(adoption.items.first?.backup)
        _ = try await f.library.apply(adoption)
        try FileManager.default.removeItem(at: f.destination)
        _ = try await f.library.releaseDeployment(f.inspection())
        _ = try await f.library.apply(f.library.plan(skill.id, desired: [f.target.id: .symlink], targets: [f.target]))
        _ = try await f.library.apply(f.library.plan(skill.id, desired: [:], targets: [f.target]))
        // A release must not silently restore an old adoption into the now-unmanaged location.
        #expect(!FileManager.default.fileExists(atPath: f.destination.path))
        let backupFile = URL(fileURLWithPath: originalBackup).appendingPathComponent("SKILL.md")
        #expect(try String(contentsOf: backupFile, encoding: .utf8).contains("Original before Muster"))
        #expect(try await f.library.load().deployments.isEmpty)
    }

    @Test func changedCopyReleasePreservesUserEditsAndOtherTargets() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.create(name: "review", description: "Library").skills.first)
        try markSkillSourcesAsLegacy(manifest: f.root.appendingPathComponent("library/skills.json"))
        let pi = SkillTarget(id: "pi", name: "Pi", directory: f.root.appendingPathComponent("pi").path)
        _ = try await f.library.apply(f.library.plan(skill.id, desired: [f.target.id: .copy, pi.id: .symlink], targets: [f.target, pi]))
        let file = f.destination.appendingPathComponent("SKILL.md")
        try "User edits".write(to: file, atomically: true, encoding: .utf8)
        let inspection = try #require(try await f.library.load().deploymentInspections.values.first { $0.deployment.targetID == f.target.id })
        #expect(inspection.status == .changed)
        let result = try await f.library.releaseDeployment(inspection)
        #expect(result.deployments.map(\.targetID) == [pi.id])
        #expect(result.deploymentInspections.values.first?.status == .active)
        #expect(try String(contentsOf: file, encoding: .utf8) == "User edits")
    }

    @Test func releaseRejectsAParentSymlinkRetargetedAfterReview() async throws {
        let f = Fixture(); defer { f.cleanup() }
        _ = try await f.deploy()
        try FileManager.default.removeItem(at: f.destination)
        let inspection = try await f.inspection()
        let parent = f.destination.deletingLastPathComponent()
        try FileManager.default.removeItem(at: parent)
        let other = f.root.appendingPathComponent("other-agent")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: other)
        await #expect(throws: SkillError.changed) { try await f.library.releaseDeployment(inspection) }
        #expect(try await f.library.load().deployments.count == 1)
    }

    @Test func replacementAfterAdoptionPreviewStillBlocksTheWrite() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let skill = try await f.deploy()
        try FileManager.default.removeItem(at: f.destination)
        try f.create(f.destination)
        _ = try await f.library.releaseDeployment(f.inspection())
        let plan = try await f.library.plan(skill.id, desired: [f.target.id: .copy], targets: [f.target], adopting: [f.destination.path])
        try "Changed after preview".write(to: f.destination.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        await #expect(throws: SkillError.changed) { try await f.library.apply(plan) }
        #expect(try String(contentsOf: f.destination.appendingPathComponent("SKILL.md"), encoding: .utf8) == "Changed after preview")
    }
}
