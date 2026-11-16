import AppKit
import MusterCore

@MainActor
final class SkillsModel: ObservableObject {
    let library: SkillLibrary
    let targets: [SkillTarget]
    @Published private(set) var availableAgentIDs: Set<String>?
    @Published private(set) var detectedAgentIDs: Set<String> = []
    var deploymentTargets: [SkillTarget] {
        targets.filter { availableAgentIDs?.contains($0.id) ?? true }.map { target in
            SkillTarget(id: target.id, name: target.name, directory: target.directory,
                discoveryDirectories: target.discoveryDirectories,
                sharedReaders: target.sharedReaders.filter { availableAgentIDs?.contains($0) ?? true })
        }
    }
    /// Targets that exist for this machine but are outside the managed scope, for honest empty states.
    var scopedOutTargets: [SkillTarget] {
        let available = Set(deploymentTargets.map(\.id))
        return targets.filter { !available.contains($0.id) }
    }
    @Published var deploymentConflict: SkillDeploymentInspection?
    @Published private(set) var snapshot = SkillLibrarySnapshot.empty
    @Published private(set) var discovered: [SkillDiscovery] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var markedIDs = Set<UUID>()
    @Published private(set) var isSelecting = false
    @Published private(set) var isBusy = false
    @Published private(set) var busyLabel = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published var search = ""
    @Published var draft = ""
    @Published private(set) var publishedText = ""
    @Published private(set) var savedDraftText = ""
    @Published private(set) var files: [String] = []
    /// The published revision folder Agents link to, for "Reveal in Finder".
    @Published private(set) var selectedDirectory: String?
    /// Every text file other than `SKILL.md` that the editor can change, keyed by relative path.
    @Published private(set) var fileTexts: [String: String] = [:]
    @Published private(set) var textFiles = Set<String>()
    @Published private(set) var desired: [String: SkillInstallMode] = [:]
    @Published private(set) var batchDesired: [String: SkillInstallMode] = [:]
    @Published var plan: SkillPlan?
    /// Kept separate from `plan` so changing an adoption inside the sheet re-renders it in place
    /// instead of dismissing and immediately re-presenting it.
    @Published var showsPlan = false
    /// Destinations the user allowed Muster to replace with a backed-up copy of the skill.
    @Published private(set) var adopting = Set<String>()
    @Published var confirmsSelection = false
    @Published var confirmsRemove = false
    @Published var showsImport = false
    @Published private(set) var candidates: [SkillCandidate] = []
    @Published var chosenCandidates = Set<String>()
    @Published var updateCandidate: SkillCandidate?
    @Published private(set) var updateText = ""
    @Published private(set) var searchFocusRequest = 0
    @Published var renaming: UUID?
    private(set) var operationTask: Task<Void, Never>?
    private var checkout: SkillCheckout?
    private var baseRevision = ""
    @Published private(set) var publishedTexts: [String: String] = [:]
    private var savedFiles: [String: String] = [:]
    private var savedRemoved = Set<String>()
    @Published private(set) var removedFiles = Set<String>()
    private var pendingSelection: UUID?
    private var undoing = false
    /// The skill an inline Agent switch is reviewing, when it is not the selected one.
    private var inlineSkillID: UUID?
    private var inlineDesired: [String: SkillInstallMode] = [:]
    private var inlineTargetIDs: Set<String>?
    private var presentsRedeployment = false
    private var didLoad = false
    private var reloadRequested = false

    init(library: SkillLibrary = SkillLibrary(), targets: [SkillTarget] = AgentRegistry.skillTargets()) {
        self.library = library; self.targets = targets
    }
    var selected: SkillRecord? { snapshot.skills.first { $0.id == selectedID } }
    var dirty: Bool { draft != publishedText || currentFiles != publishedTexts }
    var unsaved: Bool { draft != savedDraftText || currentFiles != savedFiles || removedFiles != savedRemoved }
    var currentFiles: [String: String] {
        fileTexts.filter { !removedFiles.contains($0.key) }
    }
    var deploymentDirty: Bool {
        let visible = Set(deploymentTargets.map(\.id))
        let saved = Dictionary(uniqueKeysWithValues: snapshot.deployments
            .filter { $0.skillID == selectedID && visible.contains($0.targetID) }.map { ($0.targetID, $0.mode) })
        return desired.filter { visible.contains($0.key) } != saved
    }
    var batchDirty: Bool {
        guard isSelecting, !markedIDs.isEmpty else { return false }
        let visible = Set(deploymentTargets.map(\.id))
        return markedIDs.contains { id in
            let saved = Dictionary(uniqueKeysWithValues: snapshot.deployments
                .filter { $0.skillID == id && visible.contains($0.targetID) }.map { ($0.targetID, $0.mode) })
            return batchDesired.filter { visible.contains($0.key) } != saved
        }
    }
    /// Deployed skills whose library version differs from what the Agent folder holds.
    var staleDeployments: Int {
        snapshot.deployments.filter { deployment in
            snapshot.skills.first { $0.id == deployment.skillID }?.revision != deployment.revision
        }.count
    }
    var pendingItems: Int {
        batchDirty ? markedIDs.count : (deploymentDirty ? 1 : 0)
    }
    var isBatch: Bool { isSelecting && !markedIDs.isEmpty }
    var canPublish: Bool { dirty && baseRevision == selected?.revision && !isBusy }
    var visibleSkills: [SkillRecord] {
        let words = search.split(whereSeparator: \.isWhitespace)
        return snapshot.skills.filter { skill in words.allSatisfy { (skill.name + " " + skill.summary).localizedStandardContains(String($0)) } }
    }
    var canRemove: Bool {
        guard let skill = selected, !isBusy else { return false }
        return !snapshot.deployments.contains { $0.skillID == skill.id } && !snapshot.suspendedSkillIDs.contains(skill.id)
    }

    struct DiscoveryAccess {
        let enabled: Bool
        let canToggle: Bool
        let message: String
    }

    func discoveryAccess(_ found: SkillDiscovery, agentID: String) -> DiscoveryAccess {
        guard found.digest != nil else {
            return DiscoveryAccess(enabled: false, canToggle: false, message: found.issue ?? SkillError.invalidDocument.rawValue)
        }
        let entries = discovered.filter { $0.suspendedID == nil && $0.isSameSkill(as: found) && $0.readers.contains(agentID) }
        let enabled = !entries.isEmpty
        guard deploymentTargets.contains(where: { $0.id == agentID }) else {
            return DiscoveryAccess(enabled: false, canToggle: false, message: "Skill deployment is unavailable for this Agent.")
        }
        if managedDiscoveryDeployment(found, agentID: agentID) != nil {
            return DiscoveryAccess(enabled: true, canToggle: true,
                message: "Click to undo this Muster deployment. Other readers of its shared directory may also be affected.")
        }
        if enabled {
            guard entries.count == 1, let entry = entries.first, !entry.isShared, entry.readers == [agentID],
                  !discovered.contains(where: { other in
                      other.suspendedID == nil && other.resolvedPath == entry.resolvedPath &&
                          entry.fingerprint?.hasPrefix("tree:") == true && other.readers.contains { $0 != agentID }
                  }) else {
                return DiscoveryAccess(enabled: true, canToggle: false, message: SkillError.localSkillShared.rawValue)
            }
        }
        return DiscoveryAccess(enabled: enabled, canToggle: true,
                               message: enabled ? "Disable locally; the original entry is kept for restoration."
                                                : "Enable for this Agent; import into the library automatically if needed.")
    }

    private func managedDiscoveryDeployment(_ found: SkillDiscovery, agentID: String) -> SkillDeployment? {
        snapshot.deployments.first { deployment in
            deployment.targetID == agentID && deployment.revision == found.digest &&
                snapshot.skills.contains { $0.id == deployment.skillID && $0.name == found.name } &&
                snapshot.deploymentInspections[deployment.id]?.status == .active
        }
    }

    func toggleDiscovered(_ found: SkillDiscovery, target: SkillTarget) {
        guard !isBusy, discoveryAccess(found, agentID: target.id).canToggle else { return }
        let wasEnabled = discoveryAccess(found, agentID: target.id).enabled
        let owned = managedDiscoveryDeployment(found, agentID: target.id)
        let resetEditor = !deploymentDirty
        run("Updating deployment") {
            guard self.deploymentTargets.contains(where: { $0.id == target.id }) else { throw SkillError.outsideScope }
            if let owned {
                self.snapshot = try await self.library.load()
                if let inspection = self.snapshot.deploymentInspections[owned.id], inspection.status != .active {
                    self.deploymentConflict = inspection
                    return
                }
                let plan = try await self.library.plan(owned.skillID, desired: [:], targets: self.targets, targetIDs: [target.id])
                guard plan.canApply, plan.items.count == 1, plan.items.first?.before == owned else { throw SkillError.changed }
                try self.checkScope(plan)
                self.snapshot = try await self.library.apply(plan)
            } else if wasEnabled {
                self.snapshot = try await self.library.suspendDiscovered(found, targetID: target.id, targets: self.targets)
                self.notice = L10n.t("Skill disabled for this Agent. Its original entry is saved and can be restored.")
            } else {
                let fresh = try await self.library.discover(targets: self.targets)
                guard !fresh.contains(where: { $0.suspendedID == nil && $0.isSameSkill(as: found) && $0.readers.contains(target.id) }) else { throw SkillError.changed }
                if let suspended = fresh.first(where: { $0.suspendedID != nil && $0.isSameSkill(as: found) && $0.readers.contains(target.id) }),
                   let id = suspended.suspendedID {
                    self.snapshot = try await self.library.restoreDiscovered(id, targetID: target.id, targets: self.targets)
                    self.notice = L10n.t("Original skill entry restored.")
                } else {
                    let skill = try await self.library.importDiscovered(found)
                    self.snapshot = try await self.library.load()
                    var plan = try await self.library.plan(skill.id, desired: [target.id: .symlink],
                        targets: self.targets, targetIDs: [target.id])
                    if !plan.adoptablePaths.isEmpty, plan.items.allSatisfy({ $0.conflict == nil || ($0.adoptable && $0.conflict == SkillError.occupied.rawValue) }) {
                        let previous = plan
                        plan = try await self.library.plan(skill.id, desired: [target.id: .symlink], targets: self.targets,
                            targetIDs: [target.id], adopting: Set(previous.adoptablePaths))
                        guard plan.libraryRevision == previous.libraryRevision,
                              plan.items.count == previous.items.count,
                              plan.items.allSatisfy({ item in previous.items.contains { $0.path == item.path && $0.expected == item.expected && $0.resolvedParent == item.resolvedParent } })
                        else { throw SkillError.changed }
                    }
                    try self.checkScope(plan)
                    self.snapshot = try await self.library.apply(plan)
                    self.notice = L10n.t("Skill imported and enabled. Original source files were kept.")
                }
            }
            try await self.refresh()
            if owned != nil {
                self.notice = L10n.t(self.discoveryAccess(found, agentID: target.id).enabled
                    ? "Muster deployment removed. This Agent can still read the skill from another source."
                    : "Muster deployment removed. Original source files were kept.")
            }
            if let id = self.selectedID, resetEditor { self.resetDesired(id) }
        }
    }

    func focusSearch() { searchFocusRequest += 1 }
    func restrictToAgents(_ ids: Set<String>) {
        if availableAgentIDs != ids {
            availableAgentIDs = ids
            plan = nil // A preview made before an installation change must be reviewed again.
        }
    }
    func restrictToDetectedAgents(_ ids: Set<String>) { detectedAgentIDs = ids }
    func load(force: Bool = false) {
        guard force || !didLoad else { return }
        if isBusy { if force { reloadRequested = true }; return }
        run("Loading skills") {
            let reloadEditor = !self.dirty && !self.unsaved
            try await self.refresh()
            self.didLoad = true
            if self.selectedID == nil, let first = self.snapshot.skills.first { try await self.selectNow(first.id) }
            else if reloadEditor, !self.dirty, !self.unsaved, let id = self.selectedID {
                try await self.selectNow(id, preservingDraft: true)
            }
        }
    }
    func select(_ id: UUID) {
        guard id != selectedID, !isBusy else { return }
        if unsaved || (isBatch ? batchDirty : deploymentDirty) { pendingSelection = id; confirmsSelection = true }
        else { run("Loading skill") { try await self.selectNow(id) } }
    }
    func resolveSelection(save: Bool) {
        guard let next = pendingSelection else { return }
        run("Switching skill") {
            if !save, let id = self.selectedID { try await self.library.discardDraft(id) }
            if save, let id = self.selectedID { try await self.saveDraftNow(id) }
            self.pendingSelection = nil
            try await self.selectNow(next)
        }
    }

    // MARK: - Batch selection

    /// Marking only changes the batch. Reading a skill stays on `select`, so adding a second
    /// entry never yanks the editor away from what the user was reading.
    func beginSelection() { isSelecting = true; markedIDs = []; batchDesired = [:] }
    func endSelection() { isSelecting = false; markedIDs = []; batchDesired = [:] }
    func mark(_ id: UUID) {
        guard isSelecting, let skill = snapshot.skills.first(where: { $0.id == id }) else { return }
        if markedIDs.isEmpty { batchDesired = deployments(of: skill) }
        if !markedIDs.insert(id).inserted { markedIDs.remove(id) }
    }
    func markAll() {
        if !isSelecting { beginSelection() }
        if markedIDs.isEmpty, let first = visibleSkills.first { batchDesired = deployments(of: first) }
        markedIDs = Set(visibleSkills.map(\.id))
    }
    func clearMarks() { markedIDs = []; batchDesired = [:] }

    /// A matching source is already imported; a matching name alone may be a different skill.
    func importedSkill(for discovery: SkillDiscovery) -> SkillRecord? {
        guard let digest = discovery.digest else { return nil }
        return snapshot.skills.first { $0.name == discovery.name && $0.revision == digest }
    }

    // MARK: - Editor

    func setEnabled(_ target: SkillTarget, _ on: Bool) {
        if isBatch {
            if on { batchDesired[target.id] = .symlink } else { batchDesired[target.id] = nil }
        } else if on { desired[target.id] = .symlink } else { desired[target.id] = nil }
    }
    func setMode(_ target: SkillTarget, _ mode: SkillInstallMode) {
        if isBatch { batchDesired[target.id] = mode } else { desired[target.id] = mode }
    }
    func mode(_ target: SkillTarget) -> SkillInstallMode {
        (isBatch ? batchDesired[target.id] : desired[target.id]) ?? .symlink
    }
    func isEnabled(_ target: SkillTarget) -> Bool {
        (isBatch ? batchDesired[target.id] : desired[target.id]) != nil
    }

    func saveDraft() {
        guard let id = selectedID else { return }
        run("Saving draft") {
            try await self.saveDraftNow(id)
            self.notice = L10n.t("Draft saved. Agent files are unchanged.")
        }
    }
    func discardDraft() {
        guard let id = selectedID else { return }
        run("Discarding draft") { try await self.library.discardDraft(id); try await self.selectNow(id) }
    }
    func publish() {
        guard let id = selectedID, canPublish else { return }
        run("Publishing version") {
            self.snapshot = try await self.library.publish(id, expectedRevision: self.baseRevision, text: self.draft,
                files: self.currentFiles, removed: Array(self.removedFiles))
            try await self.selectNow(id)
            self.notice = L10n.t("Library version saved. Preview deployment to update your Agents.")
        }
    }
    func openFile(_ path: String) {
        if !fileTexts.keys.contains(path) { fileTexts[path] = "" }
    }
    func addFile(path: String) {
        guard !path.isEmpty else { return }
        run("Adding file") {
            try SkillPaths.validate(path)
            guard path != "SKILL.md", !self.files.contains(path) else { throw SkillError.invalidFileName }
            self.fileTexts[path] = ""
            self.textFiles.insert(path)
            self.removedFiles.remove(path)
        }
    }
    func setFileText(_ path: String, _ text: String) {
        guard path != "SKILL.md" else { return }
        fileTexts[path] = text
        textFiles.insert(path)
        removedFiles.remove(path)
    }
    func removeFile(_ path: String) {
        guard path != "SKILL.md" else { return }
        removedFiles.insert(path)
        fileTexts[path] = nil
        textFiles.remove(path)
    }
    func restoreFile(_ path: String) {
        removedFiles.remove(path)
        if let original = publishedTexts[path] { fileTexts[path] = original; textFiles.insert(path) }
    }

    func restore(_ revision: String) {
        guard let skill = selected, !dirty else { return }
        run("Restoring version") {
            self.snapshot = try await self.library.restoreRevision(skill.id, expectedRevision: skill.revision, revision: revision)
            try await self.selectNow(skill.id)
            self.notice = L10n.t("Library version restored. Preview deployment to update your Agents.")
        }
    }

    // MARK: - Deployment

    /// Inline switches back up existing skills automatically; batch and recovery keep previews.
    func toggleDeployment(_ skill: SkillRecord, target: SkillTarget) {
        guard !isBusy else { return }
        var next = deployments(of: skill)
        if next.removeValue(forKey: target.id) == nil { next[target.id] = .symlink }
        updateDeployment(skill, to: next, targetID: target.id)
    }

    /// Switches an existing deployment between a symbolic link and a copy.
    func setDeploymentMode(_ skill: SkillRecord, target: SkillTarget, _ mode: SkillInstallMode) {
        guard !isBusy else { return }
        var next = deployments(of: skill)
        guard next[target.id] != nil, next[target.id] != mode else { return }
        next[target.id] = mode
        updateDeployment(skill, to: next, targetID: target.id)
    }

    private func deployments(of skill: SkillRecord) -> [String: SkillInstallMode] {
        Dictionary(uniqueKeysWithValues: snapshot.deployments
            .filter { $0.skillID == skill.id }.map { ($0.targetID, $0.mode) })
    }

    private func updateDeployment(_ skill: SkillRecord, to next: [String: SkillInstallMode], targetID: String) {
        let resetEditor = selectedID == skill.id && !deploymentDirty
        run("Updating deployment") {
            let targets = self.deploymentTargets
            guard targets.contains(where: { $0.id == targetID }) else { throw SkillError.outsideScope }
            self.snapshot = try await self.library.load()
            if let deployment = self.snapshot.deployments.first(where: { $0.skillID == skill.id && $0.targetID == targetID }),
               let inspection = self.snapshot.deploymentInspections[deployment.id], inspection.status != .active {
                self.deploymentConflict = inspection
                return
            }
            var plan = try await self.library.plan(skill.id, desired: next, targets: targets,
                targetIDs: [targetID], adopting: [])
            guard !plan.items.isEmpty else { return }
            if !plan.adoptablePaths.isEmpty,
               plan.items.allSatisfy({ $0.conflict == nil || ($0.adoptable && $0.conflict == SkillError.occupied.rawValue) }) {
                let initial = plan
                plan = try await self.library.plan(skill.id, desired: next, targets: targets,
                    targetIDs: [targetID], adopting: Set(initial.adoptablePaths))
                // Don't adopt a different entry if another tool changed it between the two reads.
                guard plan.libraryRevision == initial.libraryRevision, plan.items.count == initial.items.count,
                      plan.items.allSatisfy({ item in initial.items.contains {
                          $0.path == item.path && $0.expected == item.expected && $0.resolvedParent == item.resolvedParent
                      } }) else { throw SkillError.changed }
            }
            guard plan.canApply else {
                self.inlineSkillID = skill.id
                self.inlineDesired = next
                self.inlineTargetIDs = [targetID]
                self.undoing = false
                self.plan = plan
                self.showsPlan = true
                return
            }
            try self.checkScope(plan)
            self.snapshot = try await self.library.apply(plan)
            self.publishDiscovered(try await self.library.discover(targets: self.targets))
            if resetEditor { self.resetDesired(skill.id) }
            self.notice = L10n.t(plan.adoptions > 0
                ? "Skill enabled. The previous entry was backed up and will be restored when disabled."
                : "Deployment saved. Reload the Agent if the skill is not listed yet.")
        }
    }
    /// Resolve only the inspection the user reviewed, never the other Agent deployments.
    func resolveDeploymentConflict(redeploy: Bool) {
        guard let inspection = deploymentConflict else { return }
        let record = inspection.deployment
        run("Resolving deployment conflict") {
            guard self.deploymentTargets.contains(where: { $0.id == record.targetID }) else { throw SkillError.outsideScope }
            self.snapshot = try await self.library.releaseDeployment(inspection)
            if self.selectedID == record.skillID { self.resetDesired(record.skillID) }
            self.publishDiscovered(try await self.library.discover(targets: self.targets))
            self.notice = L10n.t("Muster management released. External files and previous backups were kept.")
            if redeploy {
                do {
                    self.inlineSkillID = record.skillID
                    self.inlineDesired = [record.targetID: record.mode]
                    self.inlineTargetIDs = [record.targetID]
                    self.adopting = []
                    self.undoing = false
                    self.plan = try await self.library.plan(record.skillID, desired: self.inlineDesired,
                        targets: self.deploymentTargets, targetIDs: [record.targetID])
                    self.presentsRedeployment = true
                } catch {
                    self.deploymentConflict = nil
                    throw error
                }
            }
            self.deploymentConflict = nil
        }
    }

    func finishConflictPresentation() {
        guard presentsRedeployment else { return }
        presentsRedeployment = false
        showsPlan = plan != nil
    }

    func refreshDeploymentConflict() {
        guard let conflict = deploymentConflict else { return }
        run("Checking deployment") {
            self.snapshot = try await self.library.load()
            let fresh = self.snapshot.deploymentInspections[conflict.id]
            self.deploymentConflict = fresh?.status == .active ? nil : fresh
        }
    }

    func preview() {
        let inlineID = inlineSkillID
        guard let id = inlineID ?? selectedID else { return }
        run("Building deployment preview") {
            self.undoing = false
            let batch = inlineID == nil && self.isBatch
            let desired = inlineID == nil ? (batch ? self.batchDesired : self.desired) : self.inlineDesired
            let ids = batch ? Array(self.markedIDs) : [id]
            let targets = self.deploymentTargets
            let visible = self.inlineTargetIDs ?? Set(targets.map(\.id))
            self.plan = batch
                ? try await self.library.planBatch(ids, mode: desired, targets: targets, targetIDs: visible, adopting: self.adopting)
                : try await self.library.plan(ids[0], desired: desired, targets: targets,
                    targetIDs: visible, adopting: self.adopting)
            self.adopting = self.adopting.intersection(Set(self.plan?.items.filter(\.adopts).map(\.path) ?? []))
            self.showsPlan = !(self.plan?.items.isEmpty ?? true)
        }
    }
    func toggleAdoption(_ path: String) {
        if adopting.contains(path) { adopting.remove(path) } else { adopting.insert(path) }
        preview()
    }
    func adoptAll() {
        for path in plan?.adoptablePaths ?? [] { adopting.insert(path) }
        preview()
    }
    func previewUndo() {
        inlineSkillID = nil; inlineDesired = [:]; inlineTargetIDs = nil
        run("Building undo preview") {
            let plan = try await self.library.undoPreview()
            try self.checkScope(plan)
            self.undoing = true; self.plan = plan; self.showsPlan = true
        }
    }
    func apply() {
        guard let plan else { return }
        run("Applying deployment") {
            try self.checkScope(plan)
            self.snapshot = try await (self.undoing ? self.library.undo(plan) : self.library.apply(plan))
            self.plan = nil
            self.inlineSkillID = nil
            self.inlineDesired = [:]
            self.inlineTargetIDs = nil
            self.adopting = []
            self.publishDiscovered(try await self.library.discover(targets: self.targets))
            if let id = self.selectedID { self.resetDesired(id) }
            if let id = self.selectedID { self.baseRevision = self.snapshot.skills.first { $0.id == id }?.revision ?? self.baseRevision }
            self.notice = L10n.t("Deployment saved. Reload the Agent if the skill is not listed yet.")
        }
    }
    func dismissPlan() {
        adopting = []
        inlineSkillID = nil
        inlineDesired = [:]
        inlineTargetIDs = nil
        plan = nil
        showsPlan = false
    }

    // MARK: - Library edits

    func create(name: String, description: String) {
        run("Creating skill") {
            self.snapshot = try await self.library.create(name: name, description: description)
            if let skill = self.snapshot.skills.first(where: { $0.name == name }) {
                self.endSelection()
                try await self.selectNow(skill.id)
            }
        }
    }
    func removeSelected() {
        guard let skill = selected else { return }
        run("Removing skill") {
            self.snapshot = try await self.library.remove(skill.id, expectedRevision: skill.revision)
            self.markedIDs.remove(skill.id)
            self.selectedID = nil
            self.discovered = self.discovered.filter { $0.name != skill.name }
            if let next = self.snapshot.skills.first { try await self.selectNow(next.id) }
            self.publishDiscovered(try await self.library.discover(targets: self.targets))
            self.notice = L10n.t("Skill removed from the library.")
        }
    }
    func renameSelected(to name: String) {
        guard let skill = selected else { return }
        run("Renaming skill") {
            self.snapshot = try await self.library.rename(skill.id, expectedRevision: skill.revision, to: name)
            self.renaming = nil
            try await self.selectNow(skill.id)
            self.publishDiscovered(try await self.library.discover(targets: self.targets))
            self.notice = L10n.t("Skill renamed. Preview deployment to update your Agents.")
        }
    }

    // MARK: - Import

    func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.prompt = L10n.t("Find skills")
        picker.begin { [weak self] response in
            guard response == .OK, let url = picker.url else { return }
            Task { @MainActor in self?.findLocal(url) }
        }
    }
    func findLocal(_ url: URL) {
        clearImport()
        showsImport = true
        run("Scanning folder") {
            self.candidates = try await Task.detached(priority: .userInitiated) { try SkillScanner.candidates(at: url) }.value
            try Task.checkCancellation()
            self.chosenCandidates = Set(self.candidates.filter(\.isValid).map(\.id))
        }
    }
    func findRepository(location: String, ref: String, subdirectory: String) {
        clearImport()
        showsImport = true
        run("Cloning repository") {
            let checkout = try await SkillRepository.fetch(SkillSource(kind: .git, location: location, ref: ref, subdirectory: subdirectory))
            self.checkout = checkout
            self.candidates = checkout.candidates
            self.chosenCandidates = Set(self.candidates.filter(\.isValid).map(\.id))
        }
    }
    func toggleCandidate(_ id: String) {
        if chosenCandidates.contains(id) { chosenCandidates.remove(id) } else { chosenCandidates.insert(id) }
    }
    func selectAllCandidates(_ on: Bool) {
        chosenCandidates = on ? Set(candidates.filter(\.isValid).map(\.id)) : []
    }
    func importChosen() {
        let chosen = candidates.filter { chosenCandidates.contains($0.id) }
        run("Importing skills") {
            for candidate in chosen {
                try Task.checkCancellation()
                self.snapshot = try await self.library.importSkill(candidate)
                self.chosenCandidates.remove(candidate.id)
            }
            if self.selectedID == nil, let first = self.snapshot.skills.first {
                try await self.selectNow(first.id)
            }
            self.endSelection()
            self.showsImport = false
            self.clearImport()
            self.publishDiscovered(try await self.library.discover(targets: self.targets))
            self.notice = L10n.t("Skills imported. Select Agents and preview deployment to enable them.")
        }
    }
    func clearImport() {
        checkout?.cleanup(); checkout = nil
        candidates = []; chosenCandidates = []
    }

    // MARK: - Updates

    /// Explains why this skill cannot be refreshed instead of silently reporting "up to date".
    var updateBlockedReason: String? {
        guard let skill = selected else { return nil }
        if skill.source.kind == .created { return SkillError.noSource.rawValue }
        if snapshot.deployments.contains(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
                == URL(fileURLWithPath: skill.source.location).standardizedFileURL.path
        }) { return SkillError.sourceIsDeployment.rawValue }
        if skill.source.kind == .local, !FileManager.default.fileExists(atPath: skill.source.location) {
            return SkillError.sourceIsDeployment.rawValue
        }
        return nil
    }
    func checkUpdate() {
        guard let skill = selected, !dirty, !isBusy else { return }
        run("Checking for updates") {
            let source = try await self.library.updateSource(skill.id)
            let candidates: [SkillCandidate]
            switch source.kind {
            case .created: throw SkillError.noSource
            case .local:
                candidates = try await Task.detached { try SkillScanner.candidates(at: URL(fileURLWithPath: source.location)) }.value
            case .git:
                self.checkout?.cleanup()
                let checkout = try await SkillRepository.fetch(source)
                self.checkout = checkout
                candidates = checkout.candidates
            }
            try Task.checkCancellation()
            guard let candidate = candidates.first(where: { $0.name == skill.name && $0.isValid }) else { throw SkillError.missing }
            if candidate.digest == skill.revision {
                self.notice = L10n.t("This skill is up to date.")
                self.checkout?.cleanup(); self.checkout = nil
                return
            }
            self.updateText = try String(contentsOf: candidate.directory.appendingPathComponent("SKILL.md"), encoding: .utf8)
            self.updateCandidate = candidate
        }
    }
    func applyUpdate() {
        guard let skill = selected, let candidate = updateCandidate else { return }
        run("Updating skill") {
            self.snapshot = try await self.library.update(skill.id, expectedRevision: skill.revision, from: candidate)
            self.updateCandidate = nil
            self.checkout?.cleanup(); self.checkout = nil
            try await self.selectNow(skill.id)
            self.notice = L10n.t("Library version saved. Preview deployment to update your Agents.")
        }
    }
    func dismissUpdate() { updateCandidate = nil; checkout?.cleanup(); checkout = nil }

    func cancel() { operationTask?.cancel() }
    func openLibrary() { NSWorkspace.shared.open(library.root) }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    // MARK: - Internals

    private func saveDraftNow(_ id: UUID) async throws {
        try await library.saveDraft(id, baseRevision: baseRevision, text: draft,
            files: currentFiles, removed: Array(removedFiles))
        savedDraftText = draft
        savedFiles = currentFiles
        savedRemoved = removedFiles
    }
    private func selectNow(_ id: UUID, preservingDraft: Bool = false) async throws {
        let previousDraft = draft
        let previousSelection = selectedID
        let content = try await library.content(id)
        if preservingDraft && (dirty || unsaved || previousDraft != draft || previousSelection != selectedID) { return }
        let pendingTargets = preservingDraft && deploymentDirty ? desired : nil
        selectedID = id
        publishedText = content.text
        publishedTexts = content.texts
        draft = content.draft?.text ?? content.text
        fileTexts = content.texts
        textFiles = Set(content.texts.keys)
        removedFiles = Set(content.draft?.removed ?? [])
        for (path, text) in content.draft?.files ?? [:] { fileTexts[path] = text; textFiles.insert(path) }
        for path in removedFiles { fileTexts[path] = nil; textFiles.remove(path) }
        savedDraftText = draft
        savedFiles = currentFiles
        savedRemoved = removedFiles
        files = content.files
        selectedDirectory = content.directory.path
        baseRevision = content.draft?.baseRevision ?? snapshot.skills.first(where: { $0.id == id })?.revision ?? ""
        resetDesired(id)
        if let pendingTargets { desired = pendingTargets }
        if baseRevision != selected?.revision { errorMessage = L10n.t("The skill changed while its draft was open. Discard the draft before editing this version.") }
    }
    private func resetDesired(_ id: UUID) {
        let saved = Dictionary(uniqueKeysWithValues: snapshot.deployments.filter { $0.skillID == id }.map { ($0.targetID, $0.mode) })
        desired = saved
    }
    private func refresh() async throws {
        snapshot = try await library.load()
        publishDiscovered(try await library.discover(targets: targets))
    }
    private func publishDiscovered(_ items: [SkillDiscovery]) {
        discovered = items
    }
    private func checkScope(_ plan: SkillPlan) throws {
        let ids = Set(deploymentTargets.map(\.id))
        guard plan.items.allSatisfy({ item in
            (item.before.map { ids.contains($0.targetID) } ?? true) && (item.after.map { ids.contains($0.targetID) } ?? true)
        }) else { throw SkillError.outsideScope }
    }
    private func run(_ label: String, _ operation: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; busyLabel = label; errorMessage = nil; notice = nil
        operationTask = Task {
            defer {
                isBusy = false; busyLabel = ""; operationTask = nil
                if reloadRequested { reloadRequested = false; load(force: true) }
            }
            do { try await operation() }
            catch is CancellationError { notice = L10n.t("Canceled") }
            catch { errorMessage = L10n.t(error.localizedDescription) }
        }
    }
}
