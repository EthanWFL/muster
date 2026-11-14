import AppKit
import MusterCore

@MainActor
final class SkillsModel: ObservableObject {
    let library: SkillLibrary
    let targets: [SkillTarget]
    @Published private(set) var availableAgentIDs: Set<String>?
    var deploymentTargets: [SkillTarget] {
        targets.filter { availableAgentIDs?.contains($0.id) ?? true }.map { target in
            SkillTarget(id: target.id, name: target.name, directory: target.directory,
                discoveryDirectories: target.discoveryDirectories,
                sharedReaders: target.sharedReaders.filter { availableAgentIDs?.contains($0) ?? true })
        }
    }
    @Published private(set) var snapshot = SkillLibrarySnapshot.empty
    @Published private(set) var discovered: [SkillDiscovery] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published var search = ""
    @Published var draft = ""
    @Published private(set) var publishedText = ""
    @Published private(set) var savedDraftText = ""
    @Published private(set) var files: [String] = []
    @Published private(set) var desired: [String: SkillInstallMode] = [:]
    @Published var plan: SkillPlan?
    @Published var confirmsSelection = false
    @Published var showsImport = false
    @Published private(set) var candidates: [SkillCandidate] = []
    @Published var chosenCandidates = Set<String>()
    @Published var updateCandidate: SkillCandidate?
    @Published private(set) var updateText = ""
    @Published private(set) var searchFocusRequest = 0
    private(set) var operationTask: Task<Void, Never>?
    private var checkout: SkillCheckout?
    private var baseRevision = ""
    private var pendingSelection: UUID?
    private var undoing = false
    private var didLoad = false
    private var reloadRequested = false

    init(library: SkillLibrary = SkillLibrary(), targets: [SkillTarget] = AgentRegistry.skillTargets()) {
        self.library = library; self.targets = targets
    }
    var selected: SkillRecord? { snapshot.skills.first { $0.id == selectedID } }
    var dirty: Bool { draft != publishedText }
    var unsaved: Bool { draft != savedDraftText }
    var deploymentDirty: Bool {
        let visible = Set(deploymentTargets.map(\.id))
        return desired.filter { visible.contains($0.key) } != Dictionary(uniqueKeysWithValues:
            snapshot.deployments.filter { $0.skillID == selectedID && visible.contains($0.targetID) }.map { ($0.targetID, $0.mode) })
    }
    var visibleSkills: [SkillRecord] {
        let words = search.split(whereSeparator: \.isWhitespace)
        return snapshot.skills.filter { skill in words.allSatisfy { (skill.name + " " + skill.summary).localizedStandardContains(String($0)) } }
    }
    var canPublish: Bool { dirty && baseRevision == selected?.revision && !isBusy }

    func focusSearch() { searchFocusRequest += 1 }
    func restrictToAgents(_ ids: Set<String>) {
        guard availableAgentIDs != ids else { return }
        availableAgentIDs = ids
        discovered = discovered.filter { !$0.readers.allSatisfy { !ids.contains($0) } }
        plan = nil // A preview made before an installation change must be reviewed again.
    }
    func load(force: Bool = false) {
        guard force || !didLoad else { return }
        if isBusy { if force { reloadRequested = true }; return }
        run {
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
        if unsaved || deploymentDirty { pendingSelection = id; confirmsSelection = true }
        else { run { try await self.selectNow(id) } }
    }
    func resolveSelection(save: Bool) {
        guard let next = pendingSelection else { return }
        run {
            if !save, let id = self.selectedID { try await self.library.discardDraft(id) }
            if save, let id = self.selectedID {
                try await self.library.saveDraft(id, baseRevision: self.baseRevision, text: self.draft)
            }
            self.pendingSelection = nil
            try await self.selectNow(next)
        }
    }
    func setEnabled(_ target: SkillTarget, _ on: Bool) {
        if on { desired[target.id] = .symlink } else { desired[target.id] = nil }
    }
    func setMode(_ target: SkillTarget, _ mode: SkillInstallMode) { desired[target.id] = mode }
    func mode(_ target: SkillTarget) -> SkillInstallMode { desired[target.id] ?? .symlink }

    func saveDraft() {
        guard let id = selectedID else { return }
        run {
            try await self.library.saveDraft(id, baseRevision: self.baseRevision, text: self.draft)
            self.savedDraftText = self.draft
            self.notice = L10n.t("Draft saved. Agent files are unchanged.")
        }
    }
    func discardDraft() {
        guard let id = selectedID else { return }
        run { try await self.library.discardDraft(id); try await self.selectNow(id) }
    }
    func publish() {
        guard let id = selectedID, canPublish else { return }
        run {
            self.snapshot = try await self.library.publish(id, expectedRevision: self.baseRevision, text: self.draft)
            try await self.selectNow(id)
            self.notice = L10n.t("Library version saved. Preview deployment to update your Agents.")
        }
    }
    func restore(_ revision: String) {
        guard let skill = selected, !dirty else { return }
        run {
            self.snapshot = try await self.library.restoreRevision(skill.id, expectedRevision: skill.revision, revision: revision)
            try await self.selectNow(skill.id)
            self.notice = L10n.t("Library version restored. Preview deployment to update your Agents.")
        }
    }
    func preview() {
        guard let id = selectedID else { return }
        run {
            self.undoing = false
            self.plan = try await self.library.plan(id, desired: self.desired, targets: self.deploymentTargets,
                targetIDs: Set(self.deploymentTargets.map(\.id)))
        }
    }
    func previewUndo() {
        run {
            let plan = try await self.library.undoPreview()
            try self.checkScope(plan)
            self.undoing = true; self.plan = plan
        }
    }
    func apply() {
        guard let plan else { return }
        run {
            try self.checkScope(plan)
            self.snapshot = try await (self.undoing ? self.library.undo(plan) : self.library.apply(plan))
            self.plan = nil
            self.publishDiscovered(try await self.library.discover(targets: self.deploymentTargets))
            if let id = self.selectedID { self.resetDesired(id) }
            self.notice = L10n.t("Deployment saved. Reload the Agent if the skill is not listed yet.")
        }
    }
    func create(name: String, description: String) {
        run {
            self.snapshot = try await self.library.create(name: name, description: description)
            if let skill = self.snapshot.skills.first(where: { $0.name == name }) { try await self.selectNow(skill.id) }
        }
    }

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
        run {
            self.candidates = try await Task.detached(priority: .userInitiated) { try SkillScanner.candidates(at: url) }.value
            try Task.checkCancellation()
            self.chosenCandidates = Set(self.candidates.filter(\.isValid).map(\.id))
        }
    }
    func findRepository(location: String, ref: String, subdirectory: String) {
        clearImport()
        showsImport = true
        run {
            let checkout = try await SkillRepository.fetch(SkillSource(kind: .git, location: location, ref: ref, subdirectory: subdirectory))
            self.checkout = checkout
            self.candidates = checkout.candidates
            self.chosenCandidates = Set(self.candidates.filter(\.isValid).map(\.id))
        }
    }
    func importChosen() {
        let chosen = candidates.filter { chosenCandidates.contains($0.id) }
        run {
            for candidate in chosen {
                try Task.checkCancellation()
                self.snapshot = try await self.library.importSkill(candidate)
                self.chosenCandidates.remove(candidate.id)
            }
            if self.selectedID == nil, let first = self.snapshot.skills.first { try await self.selectNow(first.id) }
            self.showsImport = false
            self.clearImport()
            self.notice = L10n.t("Skills imported. Select Agents and preview deployment to enable them.")
        }
    }
    func clearImport() {
        checkout?.cleanup(); checkout = nil
        candidates = []; chosenCandidates = []
    }
    func checkUpdate() {
        guard let skill = selected, !dirty else { return }
        run {
            let candidates: [SkillCandidate]
            switch skill.source.kind {
            case .created: throw SkillError.noSource
            case .local:
                candidates = try await Task.detached { try SkillScanner.candidates(at: URL(fileURLWithPath: skill.source.location)) }.value
            case .git:
                self.checkout?.cleanup()
                let checkout = try await SkillRepository.fetch(skill.source)
                self.checkout = checkout
                candidates = checkout.candidates
            }
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
        run {
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

    private func selectNow(_ id: UUID, preservingDraft: Bool = false) async throws {
        let previousDraft = draft
        let previousSelection = selectedID
        let content = try await library.content(id)
        if preservingDraft && (dirty || unsaved || previousDraft != draft || previousSelection != selectedID) { return }
        let pendingTargets = preservingDraft && deploymentDirty ? desired : nil
        selectedID = id
        publishedText = content.text
        draft = content.draft?.text ?? content.text
        savedDraftText = draft
        baseRevision = content.draft?.baseRevision ?? snapshot.skills.first(where: { $0.id == id })?.revision ?? ""
        files = content.files
        resetDesired(id)
        if let pendingTargets { desired = pendingTargets }
        if baseRevision != selected?.revision { errorMessage = L10n.t("The skill changed while its draft was open. Discard the draft before editing this version.") }
    }
    private func resetDesired(_ id: UUID) {
        desired = Dictionary(uniqueKeysWithValues: snapshot.deployments.filter { $0.skillID == id }.map { ($0.targetID, $0.mode) })
    }
    private func refresh() async throws {
        snapshot = try await library.load()
        publishDiscovered(try await library.discover(targets: deploymentTargets))
    }
    private func publishDiscovered(_ items: [SkillDiscovery]) {
        discovered = items.filter { item in item.readers.contains { availableAgentIDs?.contains($0) ?? true } }
    }
    private func checkScope(_ plan: SkillPlan) throws {
        let ids = Set(deploymentTargets.map(\.id))
        guard plan.items.allSatisfy({ item in
            (item.before.map { ids.contains($0.targetID) } ?? true) && (item.after.map { ids.contains($0.targetID) } ?? true)
        }) else { throw SkillError.outsideScope }
    }
    private func run(_ operation: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; notice = nil
        operationTask = Task {
            defer {
                isBusy = false; operationTask = nil
                if reloadRequested { reloadRequested = false; load(force: true) }
            }
            do { try await operation() }
            catch is CancellationError { notice = L10n.t("Canceled") }
            catch { errorMessage = L10n.t(error.localizedDescription) }
        }
    }
}
