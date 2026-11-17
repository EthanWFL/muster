import Foundation
import Testing
@testable import MusterCore

@Suite struct SingleSourceSkillTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("single-source-" + UUID().uuidString)
        var library: SkillLibrary { SkillLibrary(root: root.appendingPathComponent("library")) }
        var source: URL { root.appendingPathComponent("original/review") }
        var targets: [SkillTarget] {
            ["claude", "pi"].map { SkillTarget(id: $0, name: $0, directory: root.appendingPathComponent($0).path) }
        }
        func destination(_ id: String) -> URL { root.appendingPathComponent(id + "/review") }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func writeSource(_ body: String) throws {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try (SkillDocument.template(name: "review", description: "Review") + body).write(
                to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try "echo example".write(to: source.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("run.sh").path)
        }
        func candidate(git: Bool = false) throws -> SkillCandidate {
            try #require(SkillScanner.candidates(at: source, source: git ? SkillSource(kind: .git, location: "https://example.com/skills.git", ref: "main") : nil).first)
        }
        func deploy(_ skill: SkillRecord) async throws {
            _ = try await library.apply(library.plan(skill.id, desired: ["claude": .symlink, "pi": .symlink], targets: targets))
        }
        func text(_ id: String) throws -> String { try String(contentsOf: destination(id).appendingPathComponent("SKILL.md"), encoding: .utf8) }
    }

    @Test func localEditsFlowThroughAllLinksWithoutRedeploymentAndKeepOneRecord() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.writeSource("V1")
        let first = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        #expect(first.sourcePath == f.source.resolvingSymlinksInPath().path)
        try await f.deploy(first)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: f.destination("claude").path)
        try f.writeSource("V2")
        #expect(try f.text("claude").hasSuffix("V2"))
        #expect(try f.text("pi").hasSuffix("V2"))
        let updated = try await f.library.load()
        #expect(updated.skills.count == 1 && updated.skills[0].id == first.id)
        #expect(updated.skills[0].revision != first.revision)
        #expect(updated.skills[0].revisions.contains { $0.id == first.revision })
        #expect(try await f.library.importSkill(f.candidate()).skills.count == 1)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.destination("claude").path) == link)
        #expect(try await f.library.plan(first.id, desired: ["claude": .symlink, "pi": .symlink], targets: f.targets).items.isEmpty)
    }

    @Test func stableExternalSourceLinkFollowsUpstreamRetargetingWithoutRewritingAgentLinks() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.writeSource("V1")
        let alias = f.root.appendingPathComponent("upstream-current")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.source)
        let candidate = try #require(SkillScanner.candidates(at: alias, source: SkillSource(kind: .local, location: alias.path)).first)
        let skill = try #require(try await f.library.importSkill(candidate).skills.first)
        try await f.deploy(skill)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: f.destination("pi").path)
        #expect(link == skill.sourcePath)
        let next = f.root.appendingPathComponent("upstream-v2")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try (SkillDocument.template(name: "review", description: "New") + "V2").write(to: next.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: next)
        #expect(try f.text("pi").hasSuffix("V2"))
        let updated = try #require(try await f.library.load().skills.first)
        let body = try await f.library.content(skill.id).text
        _ = try await f.library.publish(skill.id, expectedRevision: updated.revision, text: body + "V3")
        #expect(try f.text("claude").hasSuffix("V3"))
        #expect(try String(contentsOf: f.source.appendingPathComponent("SKILL.md"), encoding: .utf8).hasSuffix("V1"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.destination("pi").path) == link)
    }

    @Test func managedSourceAppliesAndRollsBackContentWithStableLinks() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let original = try #require(try await f.library.create(name: "review", description: "Created").skills.first)
        let text = try await f.library.content(original.id).text
        try await f.deploy(original)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: f.destination("pi").path)
        let updated = try #require(try await f.library.publish(original.id, expectedRevision: original.revision, text: text + "V2").skills.first)
        #expect(try f.text("pi").hasSuffix("V2"))
        #expect(try f.text("claude").hasSuffix("V2"))
        _ = try await f.library.restoreRevision(original.id, expectedRevision: updated.revision, revision: original.revision)
        #expect(try f.text("pi") == text)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.destination("pi").path) == link)
    }

    @Test func gitImportsKeepAStableSourceAfterCheckoutRemovalAndUpdateTheSameRecord() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.writeSource("V1")
        let skill = try #require(try await f.library.importSkill(f.candidate(git: true)).skills.first)
        #expect(skill.sourcePath != f.source.path)
        try await f.deploy(skill)
        try FileManager.default.removeItem(at: f.source)
        #expect(try f.text("pi").hasSuffix("V1"))
        try f.writeSource("V2")
        let snapshot = try await f.library.importSkill(f.candidate(git: true))
        #expect(snapshot.skills.count == 1 && snapshot.skills[0].id == skill.id)
        #expect(snapshot.skills[0].sourcePath == skill.sourcePath)
        #expect(try f.text("claude").hasSuffix("V2"))
    }

    @Test func concurrentSourceEditsAndMissingSourcesAreNeverOverwritten() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.writeSource("V1")
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        try await f.deploy(skill)
        try f.writeSource("External V2")
        await #expect(throws: SkillError.changed) {
            try await f.library.publish(skill.id, expectedRevision: skill.revision, text: SkillDocument.template(name: "review", description: "Stale draft"))
        }
        #expect(try f.text("claude").hasSuffix("External V2"))
        try FileManager.default.removeItem(at: f.source)
        let snapshot = try await f.library.load()
        #expect(snapshot.sourceIssues[skill.id] != nil)
        #expect(snapshot.deploymentInspections.values.allSatisfy { $0.status != .active })
        await #expect(throws: SkillError.sourceUnavailable) { try await f.library.content(skill.id) }
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test func sourceRootAndAncestorCannotBeReplacedOrSuspended() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.writeSource("V1")
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        let own = SkillTarget(id: "own", name: "Own", directory: f.source.deletingLastPathComponent().path)
        #expect(try await f.library.plan(skill.id, desired: ["own": .symlink], targets: [own]).items.isEmpty)
        let found = try #require(try await f.library.discover(targets: [own]).first)
        await #expect(throws: SkillError.sourceCycle) { try await f.library.suspendDiscovered(found, targetID: "own", targets: [own]) }
        #expect(try FileManager.default.attributesOfItem(atPath: f.source.path)[.type] as? FileAttributeType == .typeDirectory)
    }

    @Test func migrationConvertsOnlyUnchangedInScopeLegacyEntriesAndBacksUpManifest() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.create(name: "review", description: "Legacy").skills.first)
        let manifest = f.root.appendingPathComponent("library/skills.json")
        try markSkillSourcesAsLegacy(manifest: manifest)
        _ = try await f.library.apply(f.library.plan(skill.id, desired: ["claude": .copy, "pi": .copy], targets: f.targets))
        let before = try Data(contentsOf: manifest)
        let migrated = try await f.library.migrateToSingleSource(targetIDs: ["claude"])
        let active = try #require(migrated.skills.first?.sourcePath)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.destination("claude").path) == active)
        #expect(try FileManager.default.attributesOfItem(atPath: f.destination("pi").path)[.type] as? FileAttributeType == .typeDirectory)
        let backups = try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("library/migration-backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == before)
        try "Foreign edit".write(to: f.destination("pi").appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let skipped = try await f.library.migrateToSingleSource(targetIDs: ["pi"])
        #expect(!skipped.migrationIssues.isEmpty)
        #expect(try f.text("pi") == "Foreign edit")
    }

    @Test func everyNewDeploymentUsesASymbolicLinkEvenForAnOldCopyPreference() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.create(name: "review", description: "Links").skills.first)
        let plan = try await f.library.plan(skill.id, desired: ["claude": .copy, "pi": .copy], targets: f.targets)
        #expect(plan.items.allSatisfy { $0.after?.mode == .symlink && $0.after?.sourcePath == skill.sourcePath })
        _ = try await f.library.apply(plan)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.destination("claude").path) == skill.sourcePath)
    }

    @Test func sourceEditsAndVersionRestorePreserveGitAndFinderMetadata() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.writeSource("V1")
        let fm = FileManager.default
        let metadata = [".git/HEAD": "ref: refs/heads/main\n", ".git/logs/HEAD": "local history", "references/.DS_Store": "Finder metadata", "nested/.git": "gitdir: ../worktrees/nested"]
        for (path, content) in metadata {
            let url = f.source.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        try await f.deploy(skill)
        let text = try await f.library.content(skill.id).text
        let updated = try #require(try await f.library.publish(skill.id, expectedRevision: skill.revision, text: text + "V2").skills.first)
        for (path, content) in metadata {
            #expect(try String(contentsOf: f.source.appendingPathComponent(path), encoding: .utf8) == content)
        }
        _ = try await f.library.restoreRevision(skill.id, expectedRevision: updated.revision, revision: skill.revision)
        for (path, content) in metadata {
            #expect(try String(contentsOf: f.source.appendingPathComponent(path), encoding: .utf8) == content)
        }
        #expect(try f.text("pi") == text)
        await #expect(throws: SkillError.invalidFileName) {
            try await f.library.publish(skill.id, expectedRevision: skill.revision, text: text, files: [".git/HEAD": "overwrite"])
        }
        await #expect(throws: SkillError.invalidFileName) {
            try await f.library.publish(skill.id, expectedRevision: skill.revision, text: text, removed: ["nested/.git"])
        }
    }

    @Test func discoveredDeploymentReusesSourceWhenConnectingAnotherAgent() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.create(name: "review", description: "Created").skills.first)
        _ = try await f.library.apply(f.library.plan(skill.id, desired: ["pi": .symlink], targets: f.targets))
        let found = try #require(try await f.library.discover(targets: f.targets).first { $0.readers.contains("pi") })
        let imported = try await f.library.importDiscovered(found)
        #expect(imported.id == skill.id)
        #expect(try await f.library.load().skills.count == 1)
        _ = try await f.library.apply(f.library.plan(imported.id, desired: ["claude": .symlink], targets: f.targets, targetIDs: ["claude"]))
        let text = try await f.library.content(skill.id).text
        _ = try await f.library.publish(skill.id, expectedRevision: skill.revision, text: text + "Updated")
        #expect(try f.text("claude") == f.text("pi"))
        #expect(try f.text("claude").hasSuffix("Updated"))
    }

    @Test(arguments: [false, true]) func migrationRetriesAfterSourceRepair(previouslyMarkedComplete: Bool) async throws {
        let f = Fixture(); defer { f.cleanup() }
        try f.writeSource("V1")
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        let manifest = f.root.appendingPathComponent("library/skills.json")
        try markSkillSourcesAsLegacy(manifest: manifest)
        _ = try await f.library.apply(f.library.plan(skill.id, desired: ["claude": .copy], targets: f.targets))
        try "invalid document".write(to: f.source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let failed = try await f.library.migrateToSingleSource(targetIDs: ["claude"])
        #expect(!failed.migrationIssues.isEmpty)
        #expect(failed.deployments.first?.mode == .copy)
        if previouslyMarkedComplete {
            var state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
            state["migratedAgents"] = ["claude"]
            try JSONSerialization.data(withJSONObject: state).write(to: manifest)
        }
        try f.writeSource("V1")
        let repaired = try await f.library.migrateToSingleSource(targetIDs: ["claude"])
        #expect(repaired.migrationIssues.isEmpty && repaired.sourceIssues.isEmpty)
        #expect(repaired.deployments.first?.mode == .symlink)
        #expect(repaired.skills.first?.sourcePath == f.source.resolvingSymlinksInPath().path)
        try f.writeSource("V2")
        #expect(try f.text("claude").hasSuffix("V2"))
    }

    @Test func sourceTransactionJournalRollsBackAnInterruptedUpdate() async throws {
        let f = Fixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.create(name: "review", description: "Journal").skills.first)
        try await f.deploy(skill)
        let before = try await f.library.content(skill.id).text
        let manifest = f.root.appendingPathComponent("library/skills.json")
        var initial = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let updated = try #require(try await f.library.publish(skill.id, expectedRevision: skill.revision, text: before + "Updated").skills.first)
        let afterState = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let updatedRecord = try #require((afterState["skills"] as? [[String: Any]])?.first)
        let path = try #require(skill.sourcePath)
        let git = URL(fileURLWithPath: path).appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "history updated after publish".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let oldDeployment = SkillDeployment(skillID: skill.id, targetID: "source", path: path, mode: .copy, revision: skill.revision, fingerprint: "tree:" + skill.revision)
        let newDeployment = SkillDeployment(skillID: skill.id, targetID: "source", path: path, mode: .copy, revision: updated.revision, fingerprint: "tree:" + updated.revision)
        initial["pending"] = ["id": UUID().uuidString, "updatedSources": [updatedRecord], "changes": [[
            "path": path, "parent": URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path,
            "expected": "tree:" + skill.revision, "sourceID": skill.id.uuidString,
            "before": try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldDeployment)),
            "after": try JSONSerialization.jsonObject(with: JSONEncoder().encode(newDeployment))
        ]]]
        try JSONSerialization.data(withJSONObject: initial).write(to: manifest)
        let recovered = try await f.library.load()
        #expect(recovered.skills.first?.revision == skill.revision)
        #expect(try f.text("claude") == before && f.text("pi") == before)
        #expect(try String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8) == "history updated after publish")
    }
}
