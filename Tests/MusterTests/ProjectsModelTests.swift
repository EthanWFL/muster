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

    @Test func wheelMembershipSurvivesReloadIndependentlyOfPinning() async throws {
        let fixture = try ProjectModelFixture()
        defer { fixture.cleanup() }
        fixture.model.add(fixture.folder.path)
        await fixture.model.operationTask?.value
        fixture.model.setWheelMember(try #require(fixture.model.selected), true)
        await fixture.model.operationTask?.value
        let reopened = ProjectsModel(library: fixture.library, store: fixture.store, defaults: fixture.defaults)
        reopened.load()
        await reopened.operationTask?.value
        #expect(reopened.wheel.entries.map(\.id) == [fixture.folder.path])
        #expect(reopened.selected?.isPinned == false)
        reopened.remove(try #require(reopened.selected))
        await reopened.operationTask?.value
        #expect(reopened.wheel.entries.isEmpty)
        reopened.add(fixture.folder.path)
        await reopened.operationTask?.value
        #expect(reopened.wheel.entries.isEmpty)
    }

    @Test func wheelNamesWrapAfterSixCharactersAndEllipsizeAfterThirteen() {
        #expect(WheelArcLabel.lines(for: "short") == ["short"])
        #expect(WheelArcLabel.lines(for: "muster") == ["muster"])
        #expect(WheelArcLabel.lines(for: "1234567") == ["123456", "7"])
        #expect(WheelArcLabel.lines(for: "1234567890123") == ["123456", "7890123"])
        #expect(WheelArcLabel.lines(for: "一二三四五六七八九十甲乙丙丁") == ["一二三四五六", "七八九十甲乙丙…"])
        #expect(WheelArcLabel.lines(for: "12345👩🏽‍💻7") == ["12345👩🏽‍💻", "7"])
    }

    @Test func hitTestMatchesEveryDrawnSectorAwayFromDividers() {
        let r = ProjectWheelController.diameter / 2
        let hub = ProjectWheelController.hubSize / 2
        for count in 1...6 {
            for index in 0..<count {
                let shape = WheelSector(index: index, count: count)
                let bounds = CGRect(x: 0, y: 0, width: 2*r, height: 2*r)
                for fraction in [-0.49, 0, 0.49] {
                    let a = shape.angle + fraction * 2 * .pi / Double(count)
                    for radius in [hub + 1, (hub + r) / 2, r - 1] {
                        let p = CGPoint(x: r + radius * cos(a), y: r + radius * sin(a))
                        #expect(shape.path(in: bounds).contains(p))
                        #expect(WheelSector.index(at: p, count: count) == index)
                    }
                }
            }
        }
        #expect(WheelSector.index(at: CGPoint(x: r, y: r), count: 6) == nil)
        #expect(WheelSector.index(at: .zero, count: 4) == nil)
        #expect(WheelSector.index(at: CGPoint(x: r, y: 2), count: 0) == nil)
    }

    @Test func bothWheelSizesStayInsideVisibleScreenAtEdgesAndCorners() {
        for area in [CGRect(x: 0, y: 60, width: 1440, height: 812),
                     CGRect(x: -1920, y: -120, width: 1920, height: 1050)] {
            for x in [area.minX, area.midX, area.maxX] {
                for y in [area.minY, area.midY, area.maxY] {
                    for size in [ProjectWheelController.hubSize, ProjectWheelController.diameter] {
                        let frame = ProjectWheelController.frame(center: CGPoint(x: x, y: y), diameter: size, within: area)
                        #expect(area.contains(frame))
                        #expect(frame.size == CGSize(width: size, height: size))
                    }
                }
            }
        }
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
