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

        #expect(model.markedIDs.isEmpty && !model.isSelecting)
        model.beginSelection()
        model.mark(first.id)
        model.mark(second.id); await model.operationTask?.value
        #expect(model.selectedID == first.id)
        #expect(model.markedIDs == [first.id, second.id])
        #expect(model.isBatch)
        // Two marks, one pending change: the bar must not claim two skills changed.
        model.setEnabled(target, true)
        #expect(model.batchDirty && model.pendingItems == 2)
        model.clearMarks()
        #expect(!model.isBatch && model.markedIDs.isEmpty)
        model.endSelection()
        #expect(!model.isSelecting)
    }

    @Test func singleBatchSelectionDoesNotDeployTheCurrentlyReadSkill() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        let reading = try #require(model.selectedID)
        let other = try #require(model.snapshot.skills.first { $0.id != reading })
        model.beginSelection()
        model.mark(other.id)
        model.setEnabled(target, true)
        model.preview(); await model.operationTask?.value
        #expect(model.plan?.skillIDs == [other.id])
        #expect(model.selectedID == reading)
        model.apply(); await model.operationTask?.value
        #expect(model.snapshot.deployments.map(\.skillID) == [other.id])
        model.mark(other.id)
        #expect(model.markedIDs.isEmpty && !model.isBatch)
    }

    @Test func discoveryMatchesAnImportedSourceRatherThanJustItsName() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = URL(fileURLWithPath: target.directory).appendingPathComponent("one")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SkillDocument.template(name: "one", description: "External skill").write(
            to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        let found = try #require(model.discovered.first)
        #expect(model.importedSkill(for: found) == nil)
        model.findLocal(folder); await model.operationTask?.value
        model.importChosen(); await model.operationTask?.value
        let imported = try #require(model.importedSkill(for: found))
        #expect(imported.source.kind == .local)
        #expect(imported.source.location == folder.path)
        #expect(model.markedIDs.isEmpty)
    }

    @Test func undoIsPresentedBeforeChangingAnyDeployment() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        let skill = try #require(model.selected)
        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        model.previewUndo(); await model.operationTask?.value
        #expect(model.showsPlan && model.plan != nil)
        #expect(model.snapshot.deployments.count == 1)
        model.dismissPlan()
        #expect(!model.showsPlan && model.snapshot.deployments.count == 1)
    }

    @Test func inlineToggleDeploysAndUndeploysWithoutLeavingTheList() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        let skill = try #require(model.snapshot.skills.first)
        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        #expect(model.errorMessage == nil)
        #expect(!model.showsPlan && model.plan == nil)
        #expect(model.snapshot.deployments.contains { $0.skillID == skill.id && $0.targetID == target.id })

        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        #expect(model.errorMessage == nil)
        #expect(model.snapshot.deployments.isEmpty)
    }

    @Test func inlineToggleIgnoresAnotherAgentsMissingDeployment() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let pi = SkillTarget(id: "pi", name: "Pi", directory: root.appendingPathComponent("pi-skills").path)
        let model = SkillsModel(library: library, targets: [target, pi])
        model.load(); await model.operationTask?.value
        let skill = try #require(model.selected)
        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        model.toggleDeployment(skill, target: pi); await model.operationTask?.value
        let missing = URL(fileURLWithPath: pi.directory).appendingPathComponent(skill.name)
        try FileManager.default.removeItem(at: missing)
        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        #expect(model.errorMessage == nil && model.plan == nil && model.deploymentConflict == nil)
        #expect(model.snapshot.deployments.map(\.targetID) == ["pi"])
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        model.toggleDeployment(skill, target: pi); await model.operationTask?.value
        #expect(model.deploymentConflict?.status == .missing)
        #expect(model.snapshot.deploymentInspections.values.first?.status == .missing)
        model.resolveDeploymentConflict(redeploy: false); await model.operationTask?.value
        #expect(model.errorMessage == nil && model.snapshot.deployments.isEmpty)
    }

    @Test func redeploymentPreviewAndAdoptionStayScopedToTheClickedAgent() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let pi = SkillTarget(id: "pi", name: "Pi", directory: root.appendingPathComponent("pi-skills").path)
        let model = SkillsModel(library: library, targets: [target, pi])
        model.load(); await model.operationTask?.value
        let skill = try #require(model.selected)
        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        model.toggleDeployment(skill, target: pi); await model.operationTask?.value
        let path = URL(fileURLWithPath: target.directory).appendingPathComponent(skill.name)
        let piPath = URL(fileURLWithPath: pi.directory).appendingPathComponent(skill.name)
        let piLink = try FileManager.default.destinationOfSymbolicLink(atPath: piPath.path)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try SkillDocument.template(name: skill.name, description: "Foreign content").write(
            to: path.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        #expect(model.deploymentConflict?.status == .changed)
        model.resolveDeploymentConflict(redeploy: true); await model.operationTask?.value
        #expect(model.errorMessage == nil && model.deploymentConflict == nil)
        model.finishConflictPresentation()
        #expect(model.showsPlan && model.plan?.canApply == false)
        #expect(model.plan?.items.map(\.path) == [path.path])
        model.adoptAll(); await model.operationTask?.value
        #expect(model.plan?.canApply == true && model.plan?.items.map(\.path) == [path.path])
        model.apply(); await model.operationTask?.value
        #expect(model.errorMessage == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: piPath.path) == piLink)
    }

    @Test func newlySupportedAgentsCanEnableAndDisableSkillsInTheirOwnDirectories() async throws {
        let (library, _, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let targets = AgentRegistry.skillTargets(home: root.path, environment: [:])
            .filter { ["dsh", "cursor", "hermes"].contains($0.id) }
        let model = SkillsModel(library: library, targets: targets)
        model.restrictToAgents(Set(targets.map(\.id)))
        model.load(); await model.operationTask?.value
        let skill = try #require(model.selected)
        for target in targets {
            let path = URL(fileURLWithPath: target.directory).appendingPathComponent(skill.name)
            model.toggleDeployment(skill, target: target); await model.operationTask?.value
            #expect(model.errorMessage == nil && !model.showsPlan)
            #expect(FileManager.default.fileExists(atPath: path.appendingPathComponent("SKILL.md").path))
            #expect(model.snapshot.deploymentInspections.values.contains { $0.deployment.targetID == target.id && $0.status == .active })
            model.toggleDeployment(skill, target: target); await model.operationTask?.value
            #expect(model.errorMessage == nil && !FileManager.default.fileExists(atPath: path.path))
        }
    }

    @Test func discoveredSkillImportsEnablesAndDisablesWithoutChangingItsOriginalSource() async throws {
        let (library, _, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = SkillTarget(id: "hermes", name: "Hermes", directory: root.appendingPathComponent("hermes").path)
        let b = SkillTarget(id: "pi", name: "Pi", directory: root.appendingPathComponent("pi").path)
        let source = URL(fileURLWithPath: a.directory).appendingPathComponent("local-skill")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let text = try SkillDocument.template(name: "local-skill", description: "Local skill")
        try text.write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let model = SkillsModel(library: library, targets: [a, b])
        model.load(); await model.operationTask?.value
        let found = try #require(model.discovered.first)
        #expect(model.discoveryAccess(found, agentID: a.id).enabled)
        #expect(!model.discoveryAccess(found, agentID: b.id).enabled)
        model.toggleDiscovered(found, target: b); await model.operationTask?.value
        #expect(model.errorMessage == nil && !model.showsImport && !model.showsPlan)
        #expect(model.snapshot.skills.contains { $0.name == "local-skill" })
        #expect(model.discoveryAccess(found, agentID: b.id).enabled)
        model.toggleDiscovered(found, target: b); await model.operationTask?.value
        #expect(model.errorMessage == nil && !model.discoveryAccess(found, agentID: b.id).enabled)
        #expect(model.discoveryAccess(found, agentID: a.id).enabled)
        #expect(try String(contentsOf: source.appendingPathComponent("SKILL.md"), encoding: .utf8) == text)
        model.toggleDiscovered(found, target: b); await model.operationTask?.value
        #expect(model.errorMessage == nil && model.discoveryAccess(found, agentID: b.id).enabled)
    }

    @Test func discoveryCanUndoItsOwnDeploymentInSharedAgentDirectories() async throws {
        let (library, _, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let targets = AgentRegistry.skillTargets(home: root.path, environment: [:])
        let pi = try #require(targets.first { $0.id == "pi" })
        let source = URL(fileURLWithPath: pi.directory).appendingPathComponent("local-review")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let text = try SkillDocument.template(name: "local-review", description: "Keep the original")
        try text.write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let model = SkillsModel(library: library, targets: targets)
        model.restrictToAgents(["pi", "claude", "codex"])
        model.load(); await model.operationTask?.value
        let found = try #require(model.discovered.first { $0.name == "local-review" })
        for id in ["codex", "claude"] {
            let target = try #require(targets.first { $0.id == id })
            for _ in 0..<2 {
                model.toggleDiscovered(found, target: target); await model.operationTask?.value
                #expect(model.errorMessage == nil)
                #expect(model.discoveryAccess(found, agentID: id).enabled)
                #expect(model.discoveryAccess(found, agentID: id).canToggle)
                model.toggleDiscovered(found, target: target); await model.operationTask?.value
                #expect(model.errorMessage == nil && !model.showsPlan && model.deploymentConflict == nil)
                #expect(!model.snapshot.deployments.contains { $0.targetID == id })
                #expect(!model.discoveryAccess(found, agentID: id).enabled)
                #expect(model.discoveryAccess(found, agentID: "pi").enabled)
                #expect(try String(contentsOf: source.appendingPathComponent("SKILL.md"), encoding: .utf8) == text)
            }
        }
    }

    @Test func cancelingOwnedDeploymentReportsVisibilityThatRemainsFromASharedSource() async throws {
        let (library, _, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let targets = AgentRegistry.skillTargets(home: root.path, environment: [:])
        let pi = try #require(targets.first { $0.id == "pi" })
        let codex = try #require(targets.first { $0.id == "codex" })
        let skill = try #require(try await library.create(name: "shared-review", description: "Shared").skills.first)
        _ = try await library.apply(library.plan(skill.id, desired: ["pi": .symlink, "codex": .symlink], targets: targets))
        let model = SkillsModel(library: library, targets: targets)
        model.restrictToAgents(["pi", "codex"])
        model.load(); await model.operationTask?.value
        let found = try #require(model.discovered.first { $0.name == skill.name })
        #expect(model.discoveryAccess(found, agentID: "pi").canToggle)
        model.toggleDiscovered(found, target: pi); await model.operationTask?.value
        #expect(model.errorMessage == nil && model.notice != nil)
        #expect(model.snapshot.deployments.map(\.targetID) == ["codex"])
        #expect(model.discoveryAccess(found, agentID: "pi").enabled)
        #expect(!model.discoveryAccess(found, agentID: "pi").canToggle)
        #expect(FileManager.default.fileExists(atPath: codex.directory + "/" + skill.name + "/SKILL.md"))
    }

    @Test func sharedDiscoveryIsBrightButCannotBeIndividuallyDisabledEvenOutsideManagedScope() async throws {
        let (library, _, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        let source = shared.appendingPathComponent("review")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try SkillDocument.template(name: "review", description: "Shared").write(
            to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let a = SkillTarget(id: "codex", name: "Codex", directory: shared.path, sharedReaders: ["codex", "pi"])
        let b = SkillTarget(id: "pi", name: "Pi", directory: root.appendingPathComponent("pi").path, discoveryDirectories: [shared.path])
        let model = SkillsModel(library: library, targets: [a, b])
        model.restrictToAgents(["codex"])
        model.load(); await model.operationTask?.value
        let found = try #require(model.discovered.first)
        let access = model.discoveryAccess(found, agentID: "codex")
        #expect(access.enabled && !access.canToggle)
        #expect(found.readers.contains("pi"))
        model.toggleDiscovered(found, target: a)
        #expect(!model.isBusy && FileManager.default.fileExists(atPath: source.path))
    }

    @Test func applyingTheSourceUpdatesExistingDeploymentWithoutAnotherPreview() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        let skill = try #require(model.snapshot.skills.first)
        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        #expect(model.snapshot.deployments.first?.mode == .symlink)

        model.draft += "\nNew shared content"
        model.publish(); await model.operationTask?.value
        #expect(model.errorMessage == nil)
        #expect(!model.showsPlan && model.plan == nil && model.staleDeployments == 0)
        #expect(model.snapshot.deployments.first?.mode == .symlink)
        let text = try String(contentsOfFile: target.directory + "/" + skill.name + "/SKILL.md", encoding: .utf8)
        #expect(text.hasSuffix("New shared content"))
    }

    @Test func deployingDoesNotRebaseAnOpenDraftOverExternalSourceEdits() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        let skill = try #require(model.selected)
        model.draft += "\nMy V1 draft"
        let draft = model.draft
        let external = model.publishedText + "\nExternal V2"
        let source = URL(fileURLWithPath: try #require(skill.sourcePath)).appendingPathComponent("SKILL.md")
        try external.write(to: source, atomically: true, encoding: .utf8)
        model.beginSelection()
        model.mark(skill.id)
        model.setEnabled(target, true)
        model.preview(); await model.operationTask?.value
        #expect(model.plan?.canApply == true)
        model.apply(); await model.operationTask?.value
        #expect(model.errorMessage == nil)
        #expect(model.snapshot.deployments.count == 1)
        #expect(model.draft == draft && model.dirty)
        #expect(!model.canPublish)
        model.publish(); await model.operationTask?.value
        #expect(try String(contentsOf: source, encoding: .utf8) == external)
        model.discardDraft(); await model.operationTask?.value
        #expect(model.draft == external)
        model.draft += "\nNew V2 draft"
        #expect(model.canPublish)
        model.publish(); await model.operationTask?.value
        #expect(try String(contentsOf: source, encoding: .utf8).hasSuffix("New V2 draft"))
    }

    @Test func inlineToggleBacksUpAndRestoresExistingSkillWithoutPrompts() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let occupied = URL(fileURLWithPath: target.directory).appendingPathComponent("one")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try "---\nname: one\ndescription: Hand written\n---\nMine.".write(
            to: occupied.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        let skill = try #require(model.snapshot.skills.first { $0.name == "one" })
        let other = try #require(model.snapshot.skills.first { $0.name == "two" })
        model.select(other.id); await model.operationTask?.value

        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        #expect(!model.showsPlan && model.plan == nil)
        #expect(model.errorMessage == nil)
        #expect(model.selectedID == other.id)
        #expect(try String(contentsOf: occupied.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("# one"))
        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        #expect(!model.showsPlan && model.errorMessage == nil)
        #expect(try String(contentsOf: occupied.appendingPathComponent("SKILL.md"), encoding: .utf8).hasSuffix("Mine."))
        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        #expect(!model.showsPlan && model.errorMessage == nil)
        model.previewUndo(); await model.operationTask?.value
        model.apply(); await model.operationTask?.value
        #expect(model.errorMessage == nil)
        #expect(try String(contentsOf: occupied.appendingPathComponent("SKILL.md"), encoding: .utf8).hasSuffix("Mine."))
    }

    @Test func inlineToggleNeverAdoptsANonSkillFolder() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let occupied = URL(fileURLWithPath: target.directory).appendingPathComponent("one")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        let file = occupied.appendingPathComponent("user.txt")
        try "Keep me".write(to: file, atomically: true, encoding: .utf8)
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        let skill = try #require(model.snapshot.skills.first { $0.name == "one" })
        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        #expect(model.plan?.canApply == false && model.plan?.adoptablePaths.isEmpty == true)
        #expect(model.snapshot.deployments.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Keep me")
    }

    @Test func inlineAdoptionRestoresTheOriginalSymlinkOnDisable() async throws {
        let (library, target, root) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try SkillDocument.template(name: "one", description: "Foreign").write(
            to: original.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: target.directory, withIntermediateDirectories: true)
        let link = URL(fileURLWithPath: target.directory).appendingPathComponent("one")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let model = SkillsModel(library: library, targets: [target])
        model.load(); await model.operationTask?.value
        let skill = try #require(model.snapshot.skills.first { $0.name == "one" })
        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        #expect(!model.showsPlan && model.errorMessage == nil)
        model.toggleDeployment(skill, target: target); await model.operationTask?.value
        #expect(!model.showsPlan && model.errorMessage == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == original.path)
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
