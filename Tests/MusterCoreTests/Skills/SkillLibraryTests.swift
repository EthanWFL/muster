import Foundation
import Testing
@testable import MusterCore

@Suite struct SkillLibraryTests {
    @Test func parsesMultilineYAMLAndRejectsAmbiguousOrUnsafeMetadata() throws {
        let value = try SkillDocument("---\nname: review\ndescription: |\n  Review changes.\n  Keep findings short.\nmetadata:\n  author: someone\n---\n# Content")
        #expect(value.summary == "Review changes.\nKeep findings short.")
        #expect(throws: SkillError.invalidDocument) { try SkillDocument("---\nname: first\nname: second\ndescription: hi\n---") }
        #expect(throws: SkillError.unsafeName) { try SkillDocument("---\nname: ../escape\ndescription: hi\n---") }
        #expect(throws: SkillError.invalidDocument) { try SkillDocument("---\nname: review\ndescription: [one, two]\n---") }
        #expect(try SkillDocument("---\nname: Existing_Name\ndescription: hi\n---").warning != nil)
    }

    @Test func importsCompleteFolderWithExecutableResourcesWithoutChangingOriginal() async throws {
        let f = try SkillFixture()
        defer { f.cleanup() }
        let candidate = try f.candidate()
        let snapshot = try await f.library.importSkill(candidate)
        let skill = try #require(snapshot.skills.first)
        let content = try await f.library.content(skill.id)
        #expect(content.directory.lastPathComponent == skill.name)
        #expect(Set(content.files) == ["SKILL.md", "scripts/run.sh", "references/guide.md"])
        #expect(try String(contentsOf: content.directory.appendingPathComponent("scripts/run.sh"), encoding: .utf8) == "echo example\n")
        #expect(FileManager.default.isExecutableFile(atPath: content.directory.appendingPathComponent("scripts/run.sh").path))
        #expect(try SkillFiles.hash(SkillFiles.read(f.source)) == candidate.digest)
        let duplicate = try await f.library.importSkill(candidate)
        #expect(duplicate.skills.count == 1)
        #expect(try await SkillLibrary(root: f.root.appendingPathComponent("library")).load().skills == snapshot.skills)
    }

    @Test func malformedCandidateDoesNotHideValidSiblingsAndSymlinksNeverEscape() throws {
        let f = try SkillFixture()
        defer { f.cleanup() }
        let broken = f.root.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "invalid".write(to: broken.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let result = try SkillScanner.candidates(at: f.root)
        #expect(result.filter(\.isValid).count == 1)
        #expect(result.first { $0.directory.lastPathComponent == "bad" }?.isValid == false)
        try FileManager.default.createSymbolicLink(atPath: f.source.appendingPathComponent("escape").path, withDestinationPath: f.root.path)
        #expect(try f.candidate().isValid == false)
    }

    @Test func importChecksSourceAgainAfterPreview() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let candidate = try f.candidate()
        try "changed".write(to: f.source.appendingPathComponent("references/guide.md"), atomically: true, encoding: .utf8)
        await #expect(throws: SkillError.changed) { try await f.library.importSkill(candidate) }
        #expect(try await f.library.load().skills.isEmpty)
    }

    @Test func draftAndPublishedVersionLeaveDeployedLinkUnchangedUntilApply() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        let enabled = try await f.library.plan(skill.id, desired: ["claude": .symlink], targets: f.targets)
        _ = try await f.library.apply(enabled)
        let original = try String(contentsOf: f.destination(0), encoding: .utf8)
        #expect(try await f.library.discover(targets: f.targets).allSatisfy(\.managed))
        let text = original + "\nNew instructions.\n"
        try await f.library.saveDraft(skill.id, baseRevision: skill.revision, text: text)
        #expect(try String(contentsOf: f.destination(0), encoding: .utf8) == original)
        #expect(try await f.library.content(skill.id).draft?.text == text)
        let published = try await f.library.publish(skill.id, expectedRevision: skill.revision, text: text)
        #expect(published.skills[0].revision != skill.revision)
        #expect(try String(contentsOf: f.destination(0), encoding: .utf8) == original)
        _ = try await f.library.apply(f.library.plan(skill.id, desired: ["claude": .symlink], targets: f.targets))
        #expect(try String(contentsOf: f.destination(0), encoding: .utf8) == text)
        #expect(try await f.library.content(skill.id).draft == nil)
    }

    @Test func linksCopiesDisableAndUndoRoundTrip() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        _ = try await f.library.apply(f.library.plan(skill.id, desired: ["claude": .symlink, "pi": .copy], targets: f.targets))
        #expect(try FileManager.default.attributesOfItem(atPath: f.destination(0).deletingLastPathComponent().path)[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try FileManager.default.attributesOfItem(atPath: f.destination(1).deletingLastPathComponent().path)[.type] as? FileAttributeType == .typeDirectory)
        _ = try await f.library.apply(f.library.plan(skill.id, desired: [:], targets: f.targets))
        #expect(!FileManager.default.fileExists(atPath: f.destination(0).path))
        _ = try await f.library.undo(f.library.undoPreview())
        #expect(FileManager.default.fileExists(atPath: f.destination(0).path))
        #expect(FileManager.default.fileExists(atPath: f.destination(1).path))
        _ = try await f.library.undo(f.library.undoPreview())
        #expect(try await f.library.load().deployments.isEmpty)
    }

    @Test func refusesForeignEntriesAndModifiedManagedCopies() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        try FileManager.default.createDirectory(at: f.destination(0).deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mine".write(to: f.destination(0), atomically: true, encoding: .utf8)
        let collision = try await f.library.plan(skill.id, desired: ["claude": .symlink], targets: f.targets)
        #expect(!collision.canApply)
        #expect(try String(contentsOf: f.destination(0), encoding: .utf8) == "mine")
        _ = try await f.library.apply(f.library.plan(skill.id, desired: ["pi": .copy], targets: f.targets))
        try "edited outside".write(to: f.destination(1), atomically: true, encoding: .utf8)
        #expect(try await f.library.plan(skill.id, desired: [:], targets: f.targets).canApply == false)
        #expect(try await f.library.undoPreview().canApply == false)
        #expect(try String(contentsOf: f.destination(1), encoding: .utf8) == "edited outside")
    }

    @Test func previewBecomesInvalidWhenDestinationOrItsParentChanges() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        let plan = try await f.library.plan(skill.id, desired: ["claude": .copy], targets: f.targets)
        try FileManager.default.createDirectory(at: f.destination(0).deletingLastPathComponent(), withIntermediateDirectories: true)
        try "arrived later".write(to: f.destination(0), atomically: true, encoding: .utf8)
        await #expect(throws: SkillError.changed) { try await f.library.apply(plan) }
        #expect(try String(contentsOf: f.destination(0), encoding: .utf8) == "arrived later")
        let clean = try await f.library.plan(skill.id, desired: ["pi": .copy], targets: f.targets)
        let outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.targets[1].directory, withDestinationPath: outside.path)
        await #expect(throws: SkillError.changed) { try await f.library.apply(clean) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func failedSecondTargetRollsBackFirstAndKeepsManifest() async throws {
        guard geteuid() != 0 else { return }
        let f = try SkillFixture(); defer { f.cleanup() }
        let blocked = URL(fileURLWithPath: f.targets[1].directory)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        let plan = try await f.library.plan(skill.id, desired: ["claude": .copy, "pi": .copy], targets: f.targets)
        #expect(plan.canApply)
        await #expect(throws: (any Error).self) { try await f.library.apply(plan) }
        #expect(!FileManager.default.fileExists(atPath: f.destination(0).path))
        #expect(try await f.library.load().deployments.isEmpty)
    }

    @Test func sourceUpdateIncludesRemovedAndAddedResourcesAndCanRestoreVersion() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        try FileManager.default.removeItem(at: f.source.appendingPathComponent("references/guide.md"))
        try "new resource".write(to: f.source.appendingPathComponent("references/new.md"), atomically: true, encoding: .utf8)
        let updated = try await f.library.update(skill.id, expectedRevision: skill.revision, from: f.candidate())
        #expect(try await f.library.content(skill.id).files.contains("references/new.md"))
        #expect(try await f.library.content(skill.id).files.contains("references/guide.md") == false)
        _ = try await f.library.restoreRevision(skill.id, expectedRevision: updated.skills[0].revision, revision: skill.revision)
        #expect(try await f.library.content(skill.id).files.contains("references/guide.md"))
    }

    @Test func malformedLibraryIsNeverOverwrittenAndIndependentInstancesDoNotLoseUpdates() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let first = try await f.library.create(name: "first", description: "One")
        let other = SkillLibrary(root: f.root.appendingPathComponent("library"))
        _ = try await other.create(name: "second", description: "Two")
        #expect(try await f.library.load().skills.count == 2)
        let file = f.root.appendingPathComponent("library/skills.json")
        try Data("bad".utf8).write(to: file)
        await #expect(throws: SkillError.corrupt) { try await f.library.create(name: "third", description: "Three") }
        #expect(try Data(contentsOf: file) == Data("bad".utf8))
        #expect(first.skills.count == 1)
    }

    @Test func sharedDiscoveryCombinesReadersAndDoesNotWriteAgentFolders() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let shared = f.root.appendingPathComponent(".agents/skills")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.source, to: shared.appendingPathComponent("review"))
        let targets = [SkillTarget(id: "codex", name: "Codex", directory: shared.path, sharedReaders: ["codex", "pi"]),
            SkillTarget(id: "pi", name: "Pi", directory: f.targets[1].directory, discoveryDirectories: [shared.path])]
        let found = try await f.library.discover(targets: targets)
        #expect(found.count == 1)
        #expect(found[0].isShared && !found[0].managed)
        #expect(Set(found[0].readers) == ["codex", "pi"])
        #expect(!FileManager.default.fileExists(atPath: f.targets[1].directory))
    }

    @Test func repositoryInputsAreExplicitAndCannotBecomeCommandsOrOptions() throws {
        #expect(try SkillRepository.normalizedURL("owner/repo") == "https://github.com/owner/repo")
        #expect(try SkillRepository.normalizedURL("https://example.com/team/repo.git") == "https://example.com/team/repo.git")
        for input in ["-u/--upload-pack=x", "file:///tmp/repo", "ext::sh command", "https://user:secret@host/repo", "https://github.com/a/b/tree/main/skills", "https://github.com/a/b?token=secret"] {
            #expect(throws: SkillError.invalidRepository) { try SkillRepository.normalizedURL(input) }
        }
    }
}

private struct SkillFixture {
    let root: URL
    let source: URL
    let library: SkillLibrary
    let targets: [SkillTarget]
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-test-" + UUID().uuidString)
        source = root.appendingPathComponent("original/review")
        library = SkillLibrary(root: root.appendingPathComponent("library"))
        targets = [SkillTarget(id: "claude", name: "Claude", directory: root.appendingPathComponent("claude-skills").path),
                   SkillTarget(id: "pi", name: "Pi", directory: root.appendingPathComponent("pi-skills").path)]
        for path in ["scripts", "references"] { try FileManager.default.createDirectory(at: source.appendingPathComponent(path), withIntermediateDirectories: true) }
        try "---\nname: review\ndescription: Review changes\nlicense: MIT\n---\n\nKeep findings concise.\n".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "echo example\n".write(to: source.appendingPathComponent("scripts/run.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("scripts/run.sh").path)
        try "Reference".write(to: source.appendingPathComponent("references/guide.md"), atomically: true, encoding: .utf8)
    }
    func candidate() throws -> SkillCandidate { try #require(SkillScanner.candidates(at: source).first) }
    func documentText() -> String {
        "---\nname: review\ndescription: Review changes\nlicense: MIT\n---\n\nKeep findings concise.\n"
    }
    func destination(_ index: Int) -> URL { URL(fileURLWithPath: targets[index].directory).appendingPathComponent("review/SKILL.md") }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

extension SkillLibraryTests {
    @Test func interruptedDeploymentIsRecoveredOnlyWhenItsFilesStillMatch() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        let file = f.root.appendingPathComponent("library/skills.json")
        let before = try Data(contentsOf: file)
        _ = try await f.library.apply(f.library.plan(skill.id, desired: ["claude": .copy], targets: f.targets))
        let completed = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let history = try #require(completed["history"] as? [[String: Any]])
        var interrupted = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
        interrupted["pending"] = history.last
        try JSONSerialization.data(withJSONObject: interrupted).write(to: file)
        #expect(try await f.library.load().deployments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.destination(0).path))

        _ = try await f.library.apply(f.library.plan(skill.id, desired: ["claude": .copy], targets: f.targets))
        let latest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        interrupted["pending"] = (latest["history"] as? [[String: Any]])?.last
        try JSONSerialization.data(withJSONObject: interrupted).write(to: file)
        try "external work".write(to: f.destination(0), atomically: true, encoding: .utf8)
        await #expect(throws: SkillError.recovery) { try await f.library.load() }
        #expect(try String(contentsOf: f.destination(0), encoding: .utf8) == "external work")
    }

    @Test func malformedDeepYAMLIsRejectedBeforeRecursiveParsing() {
        let brackets = String(repeating: "[", count: 1000) + String(repeating: "]", count: 1000)
        #expect(throws: SkillError.invalidDocument) { try SkillDocument("---\nname: skill\ndescription: hello\nmetadata: " + brackets + "\n---") }
    }
}

extension SkillLibraryTests {
    @Test func twoAgentRootsSharingOnePhysicalFolderAreBlockedBeforeWriting() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        try FileManager.default.createDirectory(atPath: f.targets[0].directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.targets[1].directory, withDestinationPath: f.targets[0].directory)
        let plan = try await f.library.plan(skill.id, desired: ["claude": .symlink, "pi": .copy], targets: f.targets)
        #expect(!plan.canApply)
        #expect(plan.items.allSatisfy { $0.conflict != nil })
        #expect(!FileManager.default.fileExists(atPath: f.destination(0).path))
    }
}

extension SkillLibraryTests {
    @Test func identicalContentFromDifferentSourcesKeepsSeparateProvenance() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        _ = try await f.library.importSkill(f.candidate())
        let other = f.root.appendingPathComponent("other/review")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.source, to: other)
        let candidate = try #require(SkillScanner.candidates(at: other).first)
        let snapshot = try await f.library.importSkill(candidate)
        #expect(snapshot.skills.count == 2)
        #expect(Set(snapshot.skills.map { $0.source.location }).count == 2)
    }
}

extension SkillLibraryTests {
    /// The most common real-world state: the Agent folder already holds a hand-written skill.
    @Test func existingAgentFolderIsOnlyReplacedAfterExplicitBackup() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        let destination = URL(fileURLWithPath: f.destination(0).deletingLastPathComponent().path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "---\nname: review\ndescription: Hand written\n---\nMine.".write(
            to: destination.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let blocked = try await f.library.plan(skill.id, desired: ["claude": .copy], targets: f.targets)
        #expect(!blocked.canApply)
        #expect(blocked.adoptablePaths == [f.destination(0).deletingLastPathComponent().path])
        #expect(blocked.items[0].adoptable && !blocked.items[0].adopts)
        #expect(try String(contentsOf: f.destination(0), encoding: .utf8).contains("Mine."))

        let adopting: Set<String> = [destination.path]
        let plan = try await f.library.plan(skill.id, desired: ["claude": .copy], targets: f.targets, adopting: adopting)
        #expect(plan.canApply)
        #expect(plan.adoptions == 1)
        let backup = try #require(plan.items[0].backup)
        _ = try await f.library.apply(plan)
        #expect(try String(contentsOf: f.destination(0), encoding: .utf8).contains("Keep findings concise."))
        #expect(try String(contentsOf: URL(fileURLWithPath: backup).appendingPathComponent("SKILL.md"), encoding: .utf8).contains("Mine."))

        // Disabling returns the backed-up folder instead of leaving a hole.
        _ = try await f.library.apply(f.library.plan(skill.id, desired: [:], targets: f.targets))
        #expect(try String(contentsOf: f.destination(0), encoding: .utf8).contains("Mine."))
    }

    @Test func adoptionNeverReplacesAFolderThatIsNotASkill() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        let destination = f.destination(0).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "notes".write(to: destination.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let plan = try await f.library.plan(skill.id, desired: ["claude": .copy], targets: f.targets,
            adopting: [destination.path])
        #expect(!plan.canApply)
        #expect(plan.adoptablePaths.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["notes.txt"])
    }

    @Test func removingOrRenamingStopsWhileADeploymentStillPointsAtTheOldName() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        _ = try await f.library.apply(f.library.plan(skill.id, desired: ["claude": .copy], targets: f.targets))
        await #expect(throws: SkillError.deployed) { try await f.library.remove(skill.id, expectedRevision: skill.revision) }
        await #expect(throws: SkillError.deployed) { try await f.library.rename(skill.id, expectedRevision: skill.revision, to: "renamed") }
        #expect(try await f.library.load().skills.first?.name == "review")

        _ = try await f.library.apply(f.library.plan(skill.id, desired: [:], targets: f.targets))
        let renamed = try await f.library.rename(skill.id, expectedRevision: skill.revision, to: "renamed")
        #expect(renamed.skills.first?.name == "renamed")
        // Everything besides the frontmatter name survives verbatim.
        let text = try await f.library.content(skill.id).text
        #expect(text.contains("name: renamed") && text.contains("license: MIT") && text.contains("Keep findings concise."))
        #expect(try await f.library.content(skill.id).files.contains("references/guide.md"))

        let removed = try await f.library.remove(skill.id, expectedRevision: renamed.skills[0].revision)
        #expect(removed.skills.isEmpty && removed.deployments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("library/skills/\(skill.id.uuidString)").path))
    }

    @Test func aLocalSourceThatMusterNowDeploysIntoIsNoLongerAnUpdateSource() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        #expect(try await f.library.updateSource(skill.id).location == f.source.path)
        // Importing `~/.claude/skills/review` and deploying to `~/.claude/skills` means the destination
        // *is* the imported folder, so it has to be adopted before the deployment can happen.
        let target = SkillTarget(id: "claude", name: "Claude", directory: f.source.deletingLastPathComponent().path)
        let occupied = try await f.library.plan(skill.id, desired: ["claude": .symlink], targets: [target])
        #expect(occupied.adoptablePaths == [f.source.path])
        _ = try await f.library.apply(f.library.plan(skill.id, desired: ["claude": .symlink], targets: [target],
            adopting: [f.source.path]))
        await #expect(throws: SkillError.sourceIsDeployment) { try await f.library.updateSource(skill.id) }
    }

    @Test func onePlanCanDeploySeveralSkillsAndDisableAllOfThem() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let first = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        let second = try #require(try await f.library.create(name: "second", description: "Second").skills.first { $0.name == "second" })
        let enabled = try await f.library.planBatch([first.id, second.id], mode: ["claude": .copy, "pi": .copy], targets: f.targets,
            targetIDs: ["claude", "pi"])
        #expect(enabled.items.count == 4 && enabled.canApply)
        _ = try await f.library.apply(enabled)
        #expect(try await f.library.load().deployments.count == 4)

        // An empty mode still has to remove what is deployed; targetIDs must not filter it away.
        let disabled = try await f.library.planBatch([first.id, second.id], mode: [:], targets: f.targets, targetIDs: ["claude", "pi"])
        #expect(disabled.items.count == 4)
        _ = try await f.library.apply(disabled)
        #expect(try await f.library.load().deployments.isEmpty)
    }

    @Test func draftKeepsEditsToSupportingFilesUntilPublish() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        #expect(try await f.library.content(skill.id).texts["references/guide.md"] == "Reference")
        try await f.library.saveDraft(skill.id, baseRevision: skill.revision, text: skill.revision.isEmpty ? "" : f.documentText(),
            files: ["references/guide.md": "Edited reference", "scripts/run.sh": "echo edited\n"],
            removed: [])
        let reopened = try await f.library.content(skill.id)
        #expect(reopened.texts["references/guide.md"] == "Edited reference")
        #expect(reopened.draft?.files["scripts/run.sh"] == "echo edited\n")

        let published = try await f.library.publish(skill.id, expectedRevision: skill.revision, text: f.documentText(),
            files: ["scripts/run.sh": "echo edited\n"], removed: ["references/guide.md"])
        let content = try await f.library.content(skill.id)
        #expect(!content.files.contains("references/guide.md"))
        #expect(try String(contentsOf: content.directory.appendingPathComponent("scripts/run.sh"), encoding: .utf8) == "echo edited\n")
        #expect(published.skills.first?.revision != skill.revision)
    }

    @Test func draftRejectsPathsThatEscapeTheSkillFolder() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let skill = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        for path in ["../escape.md", "/etc/passwd", "a//b.md", "./x.md", "a/../b"] {
            await #expect(throws: SkillError.invalidFileName) {
                try await f.library.publish(skill.id, expectedRevision: skill.revision, text: f.documentText(),
                    files: [path: "x"], removed: [])
            }
        }
        #expect(try await f.library.load().skills.first?.revision == skill.revision)
    }
}

extension SkillLibraryTests {
    @Test func retitlingOnlyTouchesTheFrontmatterName() throws {
        let text = "---\nname: old\ndescription: Keep me\nmetadata:\n  author: someone\n---\n\nname: body stays\n"
        let updated = try SkillDocument.retitled(text, to: "new-name")
        #expect(updated.contains("name: new-name"))
        #expect(updated.contains("description: Keep me") && updated.contains("author: someone"))
        #expect(updated.hasSuffix("name: body stays\n"))
        #expect(try SkillDocument(updated).name == "new-name")
        #expect(throws: SkillError.invalidDocument) { try SkillDocument.retitled("# no frontmatter", to: "x") }
        #expect(throws: SkillError.unsafeName) { try SkillDocument.retitled(text, to: "../escape") }
    }
}

extension SkillLibraryTests {
    /// An adoption backup must survive log rotation. Otherwise a user's original folder would be
    /// deleted once 20 newer deployments pushed the adoption out of `history`.
    @Test func adoptedFolderSurvivesHistoryRotationAndStillComesBack() async throws {
        let f = try SkillFixture(); defer { f.cleanup() }
        let adopted = try #require(try await f.library.importSkill(f.candidate()).skills.first)
        let destination = f.destination(0).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "---\nname: review\ndescription: Mine\n---\nOriginal words.".write(
            to: destination.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await f.library.apply(f.library.plan(adopted.id, desired: ["claude": .copy], targets: f.targets,
            adopting: [destination.path]))
        let backup = try #require(FileManager.default.contentsOfDirectory(
            atPath: f.root.appendingPathComponent("library/backups").path).first)
        #expect(try String(contentsOf: f.root.appendingPathComponent("library/backups/\(backup)/claude-review/SKILL.md"), encoding: .utf8).contains("Original words."))

        // Push the adoption far out of the 20-entry log.
        for index in 0..<22 {
            let name = "filler-\(index)"
            _ = try await f.library.create(name: name, description: name)
            let filler = try #require(try await f.library.load().skills.first { $0.name == name })
            _ = try await f.library.apply(f.library.plan(filler.id, desired: ["pi": .copy], targets: f.targets))
        }
        #expect(try await f.library.load().canUndo)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("library/backups/\(backup)").path))

        _ = try await f.library.apply(f.library.plan(adopted.id, desired: [:], targets: f.targets))
        #expect(try String(contentsOf: f.destination(0), encoding: .utf8).contains("Original words."))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("library/backups/\(backup)").path))
    }
}
