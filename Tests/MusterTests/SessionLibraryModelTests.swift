import Foundation
import Testing
import MusterCore
@testable import Muster

@Suite @MainActor struct SessionLibraryModelTests {
    private func source(_ id: String) -> Session {
        Session(id: id, agent: .claude, cwd: "/work/project", startedAt: Date(), state: .idle)
    }

    @Test func dirtyEditorSurvivesRefreshAndRequiresExplicitSelectionChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = SessionCatalog(url: root.appendingPathComponent("library.json"))
        let model = SessionLibraryModel(catalog: catalog, historyScanner: { _ in [] })
        let a = source("a"), b = source("b")
        model.observe(transcripts: [a, b], live: [a])
        await model.observationTask?.value
        model.select(a.key)
        model.draft.notes = "Unsaved note"
        model.observe(transcripts: [a], live: [])
        await model.observationTask?.value
        #expect(model.dirty)
        #expect(model.draft.notes == "Unsaved note")
        #expect(model.selected?.session.isProcessAlive == false)
        model.select(b.key)
        #expect(model.confirmsDiscard)
        #expect(model.selectedID == a.key)
        model.save(andSwitch: true)
        await model.operationTask?.value
        #expect(model.selectedID == b.key)
        #expect(!model.dirty)
        #expect(try await catalog.load().sessions.first { $0.id == a.key }?.annotation.notes == "Unsaved note")
        model.draft.title = "Not saved"
        model.select(a.key)
        model.discardAndSwitch()
        #expect(model.selectedID == a.key)
        #expect(model.draft.notes == "Unsaved note")
        #expect(try await catalog.load().sessions.first { $0.id == b.key }?.annotation.title == "")
    }

    @Test func staleSavePreservesDraftAndProvidesReloadBeforeRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = SessionCatalog(url: root.appendingPathComponent("library.json"))
        let model = SessionLibraryModel(catalog: catalog, historyScanner: { _ in [] })
        let a = source("a")
        model.observe(transcripts: [a], live: [])
        await model.observationTask?.value
        model.select(a.key)
        model.draft.title = "Local draft"
        _ = try await catalog.edit(a.key, expected: .init(), annotation: .init(title: "Other editor"))
        model.save()
        await model.operationTask?.value
        #expect(model.errorMessage != nil)
        #expect(model.dirty)
        #expect(model.draft.title == "Local draft")
        #expect(model.snapshot.sessions[0].annotation.title == "Other editor")
        model.reloadDraft()
        #expect(!model.dirty)
        #expect(model.draft.title == "Other editor")
    }

    @Test func firstOpenImportsThirtyDaysAndExplicitImportCanExtendHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = SessionCatalog(url: root.appendingPathComponent("library.json"))
        let recent = source("recent")
        let older = Session(id: "old", agent: .codex, cwd: "/work/old", startedAt: Date().addingTimeInterval(-45 * 86_400))
        let model = SessionLibraryModel(catalog: catalog, historyScanner: { retention in
            retention <= 30 * 86_400 ? [recent] : [recent, older]
        })
        model.open()
        await model.importTask?.value
        #expect(model.snapshot.sessions.count == 1)
        model.open()
        #expect(model.importTask == nil)
        model.importHistory(days: nil)
        await model.importTask?.value
        model.scope = .history
        #expect(model.entries().count == 2)
        model.scope = .recent
        #expect(model.entries().count == 1)
        #expect(!model.isImporting)
        #expect(model.snapshot.lastChange == nil)
    }

    @Test func canceledImportDoesNotPublishOrPersistScannedRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = SessionCatalog(url: root.appendingPathComponent("library.json"))
        let gate = DispatchSemaphore(value: 0)
        let record = source("a")
        let model = SessionLibraryModel(catalog: catalog, historyScanner: { _ in gate.wait(); return [record] })
        model.importHistory(days: nil)
        let task = try #require(model.importTask)
        model.cancelImport()
        gate.signal()
        await task.value
        #expect(!model.isImporting)
        #expect(model.errorMessage == nil)
        #expect(try await catalog.load().sessions.isEmpty)
    }

    @Test func quickActionsDoNotClobberUnsavedDetailsAndUndoPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = SessionCatalog(url: root.appendingPathComponent("library.json"))
        let model = SessionLibraryModel(catalog: catalog, historyScanner: { _ in [] })
        let record = source("a")
        model.observe(transcripts: [record], live: [])
        await model.observationTask?.value
        model.select(record.key)
        model.draft.title = "Draft"
        model.setAttention(try #require(model.selected), true)
        #expect(model.operationTask == nil)
        #expect(!model.canUndo)
        model.draft.needsAttention = true
        model.save()
        await model.operationTask?.value
        #expect(model.pendingCount == 1)
        #expect(model.canUndo)
        model.undo()
        await model.operationTask?.value
        #expect(model.pendingCount == 0)
        #expect(model.draft.title.isEmpty)
        #expect(!model.canUndo)
    }
}
