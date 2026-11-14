import Foundation
import Testing
import MusterCore
@testable import Muster

@Suite @MainActor struct ProjectsModelTests {
    @Test func addingSelectingAndRestoringAnEmptyProjectSurvivesReopen() async throws {
        let fixture = try ProjectModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.load()
        await model.operationTask?.value
        model.add(fixture.folder.path)
        await model.operationTask?.value
        #expect(model.selectedPath == fixture.folder.path)
        let added = try #require(model.selected)
        #expect(added.sessions.isEmpty)
        model.pin(added)
        await model.operationTask?.value
        model.rename(added, "Renamed")
        await model.operationTask?.value
        model.search = "RENAMED"
        #expect(model.visibleProjects.count == 1)
        model.remove(try #require(model.selected))
        await model.operationTask?.value
        #expect(model.projects.isEmpty)
        model.add(fixture.folder.path)
        await model.operationTask?.value
        #expect(model.search.isEmpty)
        let reopened = ProjectsModel(library: fixture.library, store: fixture.store, defaults: fixture.defaults)
        reopened.load()
        await reopened.operationTask?.value
        #expect(reopened.selectedPath == fixture.folder.path)
        #expect(reopened.selected?.name == "Renamed")
        #expect(reopened.selected?.isPinned == true)
    }

    @Test func sessionUpdatesRefreshProjectsWithoutDiscardingTheEditorDraft() async throws {
        let fixture = try ProjectModelFixture()
        defer { fixture.cleanup() }
        let record = Session(id: "a", agent: .codex, cwd: fixture.folder.path, startedAt: Date())
        fixture.library.observe(transcripts: [record], live: [])
        await fixture.library.observationTask?.value
        #expect(fixture.model.projects.first?.sessions.count == 1)
        fixture.library.select(record.key)
        fixture.library.draft.notes = "Saved note"
        fixture.library.draft.needsAttention = true
        fixture.library.save()
        await fixture.library.operationTask?.value
        #expect(fixture.model.selected?.pending.first?.annotation.notes == "Saved note")
        fixture.library.draft.notes = "Unsaved work"
        fixture.model.pin(try #require(fixture.model.selected))
        await fixture.model.operationTask?.value
        fixture.library.observe(transcripts: [record], live: [record])
        await fixture.library.observationTask?.value
        #expect(fixture.library.dirty)
        #expect(fixture.library.draft.notes == "Unsaved work")
        #expect(fixture.model.selected?.pending.first?.annotation.notes == "Saved note")
        #expect(fixture.model.selected?.sessions.count == 1)
    }

    @Test func failedAdditionKeepsSelectionAndReportsAnError() async throws {
        let fixture = try ProjectModelFixture()
        defer { fixture.cleanup() }
        fixture.model.add(fixture.folder.path)
        await fixture.model.operationTask?.value
        fixture.model.add(fixture.folder.path + "/missing")
        await fixture.model.operationTask?.value
        #expect(fixture.model.errorMessage != nil)
        #expect(fixture.model.selectedPath == fixture.folder.path)
        #expect(fixture.model.projects.count == 1)
        #expect(!fixture.model.isWorking)
    }
}

@MainActor private struct ProjectModelFixture {
    let folder: URL
    let suite: String
    let defaults: UserDefaults
    let store: ProjectStore
    let library: SessionLibraryModel
    let model: ProjectsModel

    init() throws {
        suite = "muster-project-test-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = ProjectStore(url: folder.appendingPathComponent("projects.json"))
        library = SessionLibraryModel(catalog: SessionCatalog(url: folder.appendingPathComponent("sessions.json")), historyScanner: { _ in [] })
        model = ProjectsModel(library: library, store: store, defaults: defaults)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
}
