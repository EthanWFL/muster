import Foundation
import Testing
@testable import MusterCore

@Suite struct DiscoveredSkillTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discovered-skill-" + UUID().uuidString)
        var library: SkillLibrary { SkillLibrary(root: root.appendingPathComponent("library")) }
        var a: SkillTarget { SkillTarget(id: "hermes", name: "Hermes", directory: root.appendingPathComponent("hermes").path) }
        var b: SkillTarget { SkillTarget(id: "pi", name: "Pi", directory: root.appendingPathComponent("pi").path) }
        var path: URL { URL(fileURLWithPath: a.directory).appendingPathComponent("review") }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func create(_ directory: URL, text: String = "Original") throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (SkillDocument.template(name: "review", description: "Review") + text).write(
                to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try "echo example".write(to: directory.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("run.sh").path)
        }
        func found() async throws -> SkillDiscovery { try #require(try await library.discover(targets: [a, b]).first) }
        var manifest: URL { root.appendingPathComponent("library/skills.json") }
    }

    @Test func independentlyDisabledDirectoryStaysDiscoverableAndRestoresItsOriginalBytes() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.create(f.path)
        let original = try SkillFiles.fingerprint(f.path)
        for _ in 0..<2 {
            _ = try await f.library.suspendDiscovered(f.found(), targetID: f.a.id, targets: [f.a, f.b])
            #expect(!FileManager.default.fileExists(atPath: f.path.path))
            let paused = try await f.found()
            let id = try #require(paused.suspendedID)
            #expect(paused.digest != nil && paused.readers == [f.a.id])
            _ = try await f.library.restoreDiscovered(id, targetID: f.a.id, targets: [f.a, f.b])
            #expect(try SkillFiles.fingerprint(f.path) == original)
            #expect(FileManager.default.isExecutableFile(atPath: f.path.appendingPathComponent("run.sh").path))
        }
    }

    @Test func relativeLinkRestoresAsTheSameLinkWithoutMovingItsTarget() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let external = f.root.appendingPathComponent("external")
        try f.create(external)
        try FileManager.default.createDirectory(atPath: f.a.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.path.path, withDestinationPath: "../external")
        _ = try await f.library.suspendDiscovered(f.found(), targetID: f.a.id, targets: [f.a, f.b])
        #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent("SKILL.md").path))
        let id = try #require(try await f.found().suspendedID)
        _ = try await f.library.restoreDiscovered(id, targetID: f.a.id, targets: [f.a, f.b])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.path.path) == "../external")
    }

    @Test func sharedAndReferencedDirectoriesCannotBeDisabledForJustOneAgent() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.create(f.path)
        let shared = SkillTarget(id: "pi", name: "Pi", directory: f.b.directory, discoveryDirectories: [f.a.directory])
        let found = try #require(try await f.library.discover(targets: [f.a, shared]).first)
        #expect(Set(found.readers) == ["hermes", "pi"])
        await #expect(throws: SkillError.localSkillShared) {
            try await f.library.suspendDiscovered(found, targetID: f.a.id, targets: [f.a, shared])
        }
        try FileManager.default.createDirectory(atPath: f.b.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: f.b.directory).appendingPathComponent("review"), withDestinationURL: f.path)
        let physical = try #require(try await f.library.discover(targets: [f.a, f.b]).first { $0.fingerprint?.hasPrefix("tree:") == true })
        await #expect(throws: SkillError.localSkillShared) {
            try await f.library.suspendDiscovered(physical, targetID: f.a.id, targets: [f.a, f.b])
        }
        #expect(FileManager.default.fileExists(atPath: f.path.path))
    }

    @Test func automaticImportCopiesAllFilesAndDeduplicatesIdenticalContentOnly() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.create(f.path)
        let found = try await f.found()
        let one = try await f.library.importDiscovered(found)
        let again = try await f.library.importDiscovered(found)
        #expect(one.id == again.id)
        let sourceHash = try SkillFiles.fingerprint(f.path)
        _ = try await f.library.apply(f.library.plan(one.id, desired: [f.b.id: .symlink], targets: [f.a, f.b]))
        #expect(try SkillFiles.fingerprint(f.path) == sourceHash)
        let content = try await f.library.content(one.id)
        #expect(content.files.contains("run.sh"))
        let other = f.root.appendingPathComponent("other/review")
        try f.create(other, text: "Different")
        let target = SkillTarget(id: "other", name: "Other", directory: other.deletingLastPathComponent().path)
        let different = try #require(try await f.library.discover(targets: [target]).first)
        #expect(!found.isSameSkill(as: different))
        #expect(try await f.library.importDiscovered(different).id != one.id)
    }

    @Test func staleDiscoveryAndOccupiedRestoreRefuseToOverwrite() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.create(f.path)
        let old = try await f.found()
        try f.create(f.path, text: "Changed")
        await #expect(throws: SkillError.changed) { try await f.library.importDiscovered(old) }
        await #expect(throws: SkillError.changed) { try await f.library.suspendDiscovered(old, targetID: f.a.id, targets: [f.a, f.b]) }
        _ = try await f.library.suspendDiscovered(f.found(), targetID: f.a.id, targets: [f.a, f.b])
        let id = try #require(try await f.found().suspendedID)
        try f.create(f.path, text: "Do not replace")
        await #expect(throws: SkillError.localSkillOccupied) { try await f.library.restoreDiscovered(id, targetID: f.a.id, targets: [f.a, f.b]) }
        #expect(try String(contentsOf: f.path.appendingPathComponent("SKILL.md"), encoding: .utf8).hasSuffix("Do not replace"))
        #expect(try await f.library.discover(targets: [f.a, f.b]).contains { $0.suspendedID == id })
    }

    @Test func managedOriginalIsNotRestoredDuringDisableAndItsRevisionCannotBeDeleted() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.create(f.path)
        let skill = try #require(try await f.library.create(name: "review", description: "Managed").skills.first)
        _ = try await f.library.apply(f.library.plan(skill.id, desired: [f.a.id: .symlink], targets: [f.a], adopting: [f.path.path]))
        _ = try await f.library.suspendDiscovered(f.found(), targetID: f.a.id, targets: [f.a, f.b])
        #expect(!FileManager.default.fileExists(atPath: f.path.path))
        await #expect(throws: SkillError.deployed) { try await f.library.remove(skill.id, expectedRevision: skill.revision) }
        let id = try #require(try await f.found().suspendedID)
        _ = try await f.library.restoreDiscovered(id, targetID: f.a.id, targets: [f.a, f.b])
        #expect(try await f.library.load().deploymentInspections.values.first?.status == .active)
        _ = try await f.library.apply(f.library.plan(skill.id, desired: [:], targets: [f.a]))
        #expect(try String(contentsOf: f.path.appendingPathComponent("SKILL.md"), encoding: .utf8).hasSuffix("Original"))
    }

    @Test func completedMoveIsRecoveredFromJournalWithoutRepeatingTheMove() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.create(f.path)
        _ = try await f.library.suspendDiscovered(f.found(), targetID: f.a.id, targets: [f.a, f.b])
        var state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.manifest)) as? [String: Any])
        let saved = try #require((state["suspended"] as? [[String: Any]])?.first)
        state["suspended"] = []
        state["pendingLocal"] = ["entry": saved, "restoring": false]
        try JSONSerialization.data(withJSONObject: state).write(to: f.manifest)
        let id = try #require(try await f.found().suspendedID)
        _ = try await f.library.load()
        #expect(try await f.library.discover(targets: [f.a, f.b]).filter { $0.suspendedID != nil }.count == 1)
        // Emulate a crash after the restoration rename but before its metadata commit.
        let backup = try #require(saved["backup"] as? String)
        try FileManager.default.moveItem(atPath: backup, toPath: f.path.path)
        state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.manifest)) as? [String: Any])
        state["pendingLocal"] = ["entry": saved, "restoring": true]
        try JSONSerialization.data(withJSONObject: state).write(to: f.manifest)
        #expect(try await f.library.discover(targets: [f.a, f.b]).allSatisfy { $0.suspendedID != id })
        #expect(FileManager.default.fileExists(atPath: f.path.path))
    }

    @Test func editedBackupIsKeptAndCannotOverwriteTheOriginalPath() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.create(f.path)
        _ = try await f.library.suspendDiscovered(f.found(), targetID: f.a.id, targets: [f.a])
        let saved = try await f.found()
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.manifest)) as? [String: Any])
        let backup = try #require((state["suspended"] as? [[String: Any]])?.first?["backup"] as? String)
        try "Changed while disabled".write(toFile: backup + "/SKILL.md", atomically: true, encoding: .utf8)
        await #expect(throws: SkillError.changed) { try await f.library.restoreDiscovered(try #require(saved.suspendedID), targetID: f.a.id, targets: [f.a]) }
        #expect(!FileManager.default.fileExists(atPath: f.path.path))
    }
}
