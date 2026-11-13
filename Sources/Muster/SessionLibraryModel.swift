import AppKit
import MusterCore
import SwiftUI

@MainActor
final class SessionLibraryModel: ObservableObject {
    @Published private(set) var snapshot: SessionCatalogSnapshot = .empty
    @Published private(set) var live: [Session] = []
    @Published var scope: SessionLibraryScope = .recent
    @Published var filter: SessionLibraryFilter = .all
    @Published private(set) var selectedID: String?
    @Published var draft = SessionAnnotation()
    @Published private(set) var editingOriginal: SessionAnnotation?
    @Published private(set) var isSaving = false
    @Published private(set) var isImporting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published var confirmsDiscard = false
    @Published private(set) var titleFocusRequest = 0
    private var pendingSelection: String?
    private var didOpen = false
    private let catalog: SessionCatalog
    private let historyScanner: @Sendable (TimeInterval) throws -> [Session]
    private(set) var loadTask: Task<Void, Never>?
    private(set) var observationTask: Task<Void, Never>?
    private(set) var operationTask: Task<Void, Never>?
    private(set) var importTask: Task<Void, Never>?

    init(catalog: SessionCatalog = SessionCatalog(),
         historyScanner: @escaping @Sendable (TimeInterval) throws -> [Session] = { retention in
             try AgentRegistry.transcriptScanners(retention: retention).flatMap { try $0.scan() }
         }) {
        self.catalog = catalog
        self.historyScanner = historyScanner
    }

    var dirty: Bool { editingOriginal.map { draft != $0 } ?? false }
    var pendingCount: Int { snapshot.sessions.filter { $0.annotation.needsAttention }.count }
    var canUndo: Bool { snapshot.lastChange != nil && !isSaving && !dirty }
    var selected: LibrarySession? {
        guard let selectedID else { return nil }
        let stored = snapshot.sessions.first { $0.id == selectedID }
        guard let session = live.first(where: { $0.key == selectedID }) ?? stored?.session else { return nil }
        return LibrarySession(session: session, stored: stored)
    }

    func entries(query: String = "", filter override: SessionLibraryFilter? = nil) -> [LibrarySession] {
        SessionLibraryBrowser(scope: scope, filter: override ?? filter, query: query).entries(snapshot: snapshot, live: live)
    }

    func load() {
        guard loadTask == nil else { return }
        loadTask = Task {
            defer { loadTask = nil }
            do { publish(try await catalog.load()); errorMessage = nil }
            catch { show(error) }
        }
    }

    func open() {
        guard !didOpen else { return }
        didOpen = true
        importHistory(days: 30)
    }

    func observe(transcripts: [Session], live: [Session]) {
        self.live = live
        let previous = observationTask
        observationTask = Task {
            // Keep successive scans ordered while allowing user edits between them.
            await previous?.value
            do { publish(try await catalog.ingest(transcripts)) }
            catch { show(error) }
        }
    }

    func importHistory(days: Int?) {
        guard !isImporting else { return }
        isImporting = true
        let scanner = historyScanner
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            let work = Task.detached(priority: .utility) {
                try scanner(days.map { Double($0) * 86_400 } ?? Date().timeIntervalSince1970 + 86_400)
            }
            do {
                let sessions = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                publish(try await catalog.ingest(sessions))
                errorMessage = nil
                notice = days == nil ? L10n.t("Imported available history. Conversation text was not stored.")
                    : L10n.t("Imported the last %d days. Conversation text was not stored.", days!)
            } catch {
                if !Task.isCancelled { show(error) }
            }
        }
    }

    func cancelImport() { importTask?.cancel() }

    func select(_ id: String) {
        guard id != selectedID, !isSaving else { return }
        if dirty { pendingSelection = id; confirmsDiscard = true; return }
        selectNow(id)
    }

    func editTitle(_ id: String) { select(id); titleFocusRequest += 1 }

    func discardAndSwitch() {
        guard let pendingSelection else { return }
        self.pendingSelection = nil
        selectNow(pendingSelection)
    }

    func reloadDraft() {
        guard let selectedID else { return }
        selectNow(selectedID)
        errorMessage = nil
    }

    func save(andSwitch: Bool = false) {
        guard let selectedID, let original = editingOriginal, !isSaving else { return }
        var saved = draft
        saved.title = saved.title.trimmingCharacters(in: .whitespacesAndNewlines)
        perform { [catalog] in try await catalog.edit(selectedID, expected: original, annotation: saved) } success: {
            if andSwitch, let next = self.pendingSelection {
                self.pendingSelection = nil
                self.selectNow(next)
            } else { self.selectNow(selectedID) }
            self.notice = L10n.t("Session details saved in Muster.")
        }
    }

    func setAttention(_ entry: LibrarySession, _ value: Bool) {
        guard let stored = entry.stored, !(selectedID == entry.id && dirty) else { return }
        var annotation = stored.annotation
        annotation.needsAttention = value
        perform { [catalog] in try await catalog.edit(entry.id, expected: stored.annotation, annotation: annotation) }
    }

    func assign(_ entry: LibrarySession, to category: UUID?) {
        guard let stored = entry.stored, !(selectedID == entry.id && dirty) else { return }
        var annotation = stored.annotation
        annotation.categoryID = category
        perform { [catalog] in try await catalog.edit(entry.id, expected: stored.annotation, annotation: annotation) }
    }

    func createCategory(_ name: String) { perform { [catalog] in try await catalog.createCategory(named: name) } }
    func renameCategory(_ category: SessionCategory, _ name: String) {
        perform { [catalog] in try await catalog.renameCategory(category, name: name) }
    }
    func deleteCategory(_ category: SessionCategory) {
        guard !dirty else { return }
        perform { [catalog] in try await catalog.deleteCategory(category) }
    }
    func undo() {
        guard canUndo, let change = snapshot.lastChange else { return }
        perform { [catalog] in try await catalog.undo(change.id) } success: {
            self.notice = L10n.t("Last organization change undone.")
        }
    }

    func chooseArtifactDirectory() {
        let selection = selectedID
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("Choose folder")
        panel.begin { [weak self] result in
            guard result == .OK, let path = panel.url?.path else { return }
            Task { @MainActor in
                guard let self, self.selectedID == selection else { return }
                self.draft.artifactDirectory = path
            }
        }
    }

    func openDirectory(_ path: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              NSWorkspace.shared.open(URL(fileURLWithPath: path)) else {
            errorMessage = L10n.t("This folder is no longer available.")
            return
        }
    }

    private func selectNow(_ id: String) {
        selectedID = id
        editingOriginal = snapshot.sessions.first { $0.id == id }?.annotation
        draft = editingOriginal ?? SessionAnnotation()
    }

    private func publish(_ value: SessionCatalogSnapshot) {
        guard value.revision >= snapshot.revision else { return }
        let wasDirty = dirty
        snapshot = value
        if case .category(let id) = filter, !value.categories.contains(where: { $0.id == id }) { filter = .all }
        if !wasDirty, let selectedID { selectNow(selectedID) }
    }

    private func perform(_ operation: @escaping () async throws -> SessionCatalogSnapshot,
                         success: @escaping () -> Void = {}) {
        guard !isSaving else { return }
        isSaving = true
        operationTask = Task {
            defer { isSaving = false; operationTask = nil }
            do {
                publish(try await operation())
                errorMessage = nil
                success()
            } catch {
                show(error)
                // Refresh other changes without discarding this editor's unsaved draft.
                if let latest = try? await catalog.load() { publish(latest) }
            }
        }
    }

    private func show(_ error: Error) { errorMessage = L10n.t(error.localizedDescription) }
}
