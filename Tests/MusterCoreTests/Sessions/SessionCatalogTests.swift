import Foundation
import Testing
@testable import MusterCore

@Suite struct SessionCatalogTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func session(_ id: String, agent: AgentKind = .claude, age: TimeInterval = 0) -> Session {
        Session(id: id, agent: agent, cwd: "/work/project", pid: 102, pidStartTime: now,
                startedAt: now.addingTimeInterval(-age - 60), lastActivityAt: now.addingTimeInterval(-age))
    }

    @Test func annotationsSurviveRestartAndFreshScansWithoutPersistingPIDs() async throws {
        let tree = try TempTree()
        let url = URL(fileURLWithPath: tree.path("library.json"))
        let catalog = SessionCatalog(url: url)
        let source = session("a")
        _ = try await catalog.ingest([source, session("proc-200"), session("b", agent: .gemini)])
        let category = try #require(try await catalog.createCategory(named: "Work").categories.first)
        let annotation = SessionAnnotation(title: "Review API", categoryID: category.id, needsAttention: true,
                                           notes: "Next: check errors", artifactDirectory: tree.root)
        _ = try await catalog.edit(source.key, expected: .init(), annotation: annotation)
        var newer = source
        newer.lastActivityAt = now.addingTimeInterval(500)
        let updated = try await catalog.ingest([newer])
        let reopened = try await SessionCatalog(url: url).load()
        let record = try #require(reopened.sessions.first)
        #expect(reopened.sessions.count == 1)
        #expect(record.annotation == annotation)
        #expect(record.lastActivityAt == newer.lastActivityAt)
        #expect(record.session.pid == nil)
        #expect(!record.session.isProcessAlive)
        #expect(reopened.lastChange?.id == updated.lastChange?.id)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("pid"))
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func separateInstancesMergeImportsAndRejectStaleEditors() async throws {
        let tree = try TempTree()
        let url = URL(fileURLWithPath: tree.path("library.json"))
        let first = SessionCatalog(url: url), second = SessionCatalog(url: url)
        let a = session("a"), b = session("b")
        async let one = first.ingest([a])
        async let two = second.ingest([b, session("a", agent: .codex)])
        _ = try await (one, two)
        _ = try await first.edit(a.key, expected: .init(), annotation: .init(title: "Saved"))
        await #expect(throws: SessionCatalogError.conflict) {
            try await second.edit(a.key, expected: .init(), annotation: .init(title: "Stale"))
        }
        let snapshot = try await second.load()
        #expect(snapshot.sessions.count == 3)
        #expect(snapshot.sessions.first { $0.id == a.key }?.annotation.title == "Saved")
    }

    @Test func categoryDeletionAndUndoKeepSessionRecordsAndNotes() async throws {
        let tree = try TempTree()
        let catalog = SessionCatalog(url: URL(fileURLWithPath: tree.path("library.json")))
        let source = session("a")
        _ = try await catalog.ingest([source])
        let category = try #require(try await catalog.createCategory(named: "Work").categories.first)
        let original = SessionAnnotation(categoryID: category.id, notes: "Keep this note")
        _ = try await catalog.edit(source.key, expected: .init(), annotation: original)
        let removed = try await catalog.deleteCategory(category)
        #expect(removed.sessions.count == 1)
        #expect(removed.sessions[0].annotation.categoryID == nil)
        #expect(removed.sessions[0].annotation.notes == original.notes)
        let restored = try await catalog.undo(try #require(removed.lastChange).id)
        #expect(restored.categories == [category])
        #expect(restored.sessions[0].annotation == original)
        let cleared = try await catalog.undo(try #require(restored.lastChange).id)
        #expect(cleared.sessions[0].annotation == SessionAnnotation())
    }

    @Test func invalidCategoriesAndMetadataLeaveFileUnchanged() async throws {
        let tree = try TempTree()
        let url = URL(fileURLWithPath: tree.path("library.json"))
        let catalog = SessionCatalog(url: url)
        let source = session("a")
        _ = try await catalog.ingest([source])
        _ = try await catalog.createCategory(named: "Work")
        let original = try Data(contentsOf: url)
        await #expect(throws: SessionCatalogError.categoryName) { try await catalog.createCategory(named: "work") }
        await #expect(throws: SessionCatalogError.invalid) {
            try await catalog.edit(source.key, expected: .init(), annotation: .init(title: "two\nlines"))
        }
        await #expect(throws: SessionCatalogError.invalid) {
            try await catalog.edit(source.key, expected: .init(), annotation: .init(artifactDirectory: "relative/path"))
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func damagedLibraryIsNeverOverwrittenByAnImport() async throws {
        let tree = try TempTree()
        let url = URL(fileURLWithPath: try tree.write("library.json", "{broken"))
        let catalog = SessionCatalog(url: url)
        await #expect(throws: SessionCatalogError.corrupt) { try await catalog.ingest([session("a")]) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{broken")
    }

    @Test func undoPreservesUnrelatedExternalEditsAndRejectsOverlappingEdits() async throws {
        let tree = try TempTree()
        let url = URL(fileURLWithPath: tree.path("library.json"))
        let catalog = SessionCatalog(url: url)
        let source = session("a")
        _ = try await catalog.ingest([source])
        var snapshot = try await catalog.edit(source.key, expected: .init(), annotation: .init(title: "New title"))
        func externalEdit(_ field: String, _ value: String) throws {
            var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var sessions = try #require(root["sessions"] as? [String: [String: Any]])
            var record = try #require(sessions[source.key])
            var annotation = try #require(record["annotation"] as? [String: Any])
            annotation[field] = value; record["annotation"] = annotation
            sessions[source.key] = record; root["sessions"] = sessions
            try JSONSerialization.data(withJSONObject: root).write(to: url, options: .atomic)
        }
        try externalEdit("notes", "Independent note")
        snapshot = try await catalog.undo(try #require(snapshot.lastChange).id)
        #expect(snapshot.sessions[0].annotation.title.isEmpty)
        #expect(snapshot.sessions[0].annotation.notes == "Independent note")
        var next = snapshot.sessions[0].annotation; next.title = "Changed again"
        snapshot = try await catalog.edit(source.key, expected: snapshot.sessions[0].annotation, annotation: next)
        try externalEdit("title", "External title")
        let bytes = try Data(contentsOf: url)
        let change = try #require(snapshot.lastChange)
        await #expect(throws: SessionCatalogError.conflict) { try await catalog.undo(change.id) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func persistedUndoIsLimitedToFiftyUserChanges() async throws {
        let tree = try TempTree()
        let url = URL(fileURLWithPath: tree.path("library.json"))
        let catalog = SessionCatalog(url: url)
        let source = session("a")
        var snapshot = try await catalog.ingest([source])
        for index in 1...52 {
            snapshot = try await catalog.edit(source.key, expected: snapshot.sessions[0].annotation,
                                             annotation: .init(title: "Title \(index)"))
        }
        let reopened = SessionCatalog(url: url)
        for _ in 0..<50 { snapshot = try await reopened.undo(try #require(snapshot.lastChange).id) }
        #expect(snapshot.lastChange == nil)
        #expect(snapshot.sessions[0].annotation.title == "Title 2")
    }

    @Test func historyMergesLiveStateAndSearchesAnnotationsWithoutInferringRunningState() async throws {
        let tree = try TempTree()
        let catalog = SessionCatalog(url: URL(fileURLWithPath: tree.path("library.json")))
        let old = session("old", age: 100_000), fresh = session("new")
        _ = try await catalog.ingest([old, fresh])
        let category = try #require(try await catalog.createCategory(named: "Research").categories.first)
        let snapshot = try await catalog.edit(old.key, expected: .init(), annotation: .init(
            title: "API plan", categoryID: category.id, needsAttention: true, notes: "Verify retries", artifactDirectory: "/output/draft"))
        let history = SessionLibraryBrowser(scope: .history)
        let entries = history.entries(snapshot: snapshot, live: [fresh, session("proc-123")], now: now)
        #expect(entries.count == 2)
        #expect(entries.first { $0.id == fresh.key }?.session.isProcessAlive == true)
        #expect(entries.first { $0.id == old.key }?.session.isProcessAlive == false)
        #expect(SessionLibraryBrowser().entries(snapshot: snapshot, live: [], now: now).count == 1)
        let search = SessionLibraryBrowser(scope: .history, filter: .attention, query: "api RESEARCH retries draft")
        #expect(search.entries(snapshot: snapshot, live: [], now: now).map(\.id) == [old.key])
        #expect(SessionBrowser(query: "API plan").groups(in: [old], titles: [old.key: "API plan"]).first?.sessions == [old])
    }
}

@Suite struct SessionResumerTests {
    @Test func passesQuotedResumeCommandAsDataToAFreshTerminal() throws {
        let tree = try TempTree()
        let folder = tree.path("it's here; $(touch should-not-run)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let source = Session(id: "session-1", agent: .codex, cwd: folder, startedAt: Date())
        let runner = CleanupStubRunner { _, _ in CommandResult(status: 0, stdout: "") }
        try SessionResumer(runner: runner).resume(source)
        let call = try #require(runner.calls.first)
        #expect(call[0] == "osascript")
        #expect(!call[2].contains(folder))
        #expect(call[2].contains("do script (item 1 of argv)"))
        #expect(call[3] == "--")
        #expect(call[4] == source.resumeCommand)
    }

    @Test func rejectsMissingFoldersAndUnsupportedIDsBeforeLaunching() throws {
        let runner = CleanupStubRunner { _, _ in CommandResult(status: 0, stdout: "") }
        let resumer = SessionResumer(runner: runner)
        #expect(throws: SessionResumeError.unavailable) {
            try resumer.resume(Session(id: "proc-1", agent: .claude, cwd: "/tmp", startedAt: Date()))
        }
        #expect(throws: SessionResumeError.folderMissing) {
            try resumer.resume(Session(id: "a", agent: .claude, cwd: "/missing-\(UUID())", startedAt: Date()))
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func automationFailureCanFallBackToClipboard() throws {
        let runner = CleanupStubRunner { _, _ in CommandResult(status: 1, stdout: "") }
        #expect(throws: SessionResumeError.automation) {
            try SessionResumer(runner: runner).resume(Session(id: "a", agent: .claude, cwd: "/tmp", startedAt: Date()))
        }
    }
}
