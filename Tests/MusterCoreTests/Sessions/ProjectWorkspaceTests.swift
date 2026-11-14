import Foundation
import Testing
@testable import MusterCore

@Suite struct ProjectWorkspaceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, _ path: String, agent: AgentKind = .codex, ago: TimeInterval = 0,
                         pid: Int32? = nil) -> Session {
        Session(id: id, agent: agent, cwd: path, pid: pid, startedAt: now.addingTimeInterval(-ago))
    }

    @Test func registrationNormalizesPathsAndKeepsEmptyProjectsAcrossReopen() async throws {
        let root = try makeSessionsTempDir("projects")
        defer { removeSessionsTempDir(root) }
        let url = root.appendingPathComponent("projects.json")
        let store = ProjectStore(url: url)
        _ = try await store.add(root.path + "/./")
        _ = try await store.add(root.path)
        _ = try await store.pin(root.path, true)
        _ = try await store.rename(root.path, "  My project  ")
        let reopened = try await ProjectStore(url: url).load()
        #expect(reopened.records.count == 1)
        let project = try #require(ProjectWorkspace.projects(records: reopened.records, snapshot: .empty, live: []).first)
        #expect(project.path == root.path)
        #expect(project.name == "My project")
        #expect(project.isPinned && project.sessions.isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func discoveredProjectsUseFullPathsAndIgnoreUnknownDirectories() {
        let projects = ProjectWorkspace.projects(records: [], snapshot: .empty, live: [
            session("a", "/work/one/app"), session("b", "/work/two/app"),
            session("c", "/work/one/app/./"), session("d", ""), session("e", "relative/path")
        ])
        #expect(projects.count == 2)
        #expect(Set(projects.map(\.name)) == ["app"])
        #expect(projects.first { $0.path == "/work/one/app" }?.sessions.count == 2)
    }

    @Test func explicitRootsOwnDescendantsWithNestedProjectsTakingPrecedence() {
        let records = [ProjectRecord(path: "/work/app"), ProjectRecord(path: "/work/app/tools")]
        let projects = ProjectWorkspace.projects(records: records, snapshot: .empty, live: [
            session("root", "/work/app"), session("source", "/work/app/src"),
            session("nested", "/work/app/tools/scripts"), session("neighbor", "/work/application")
        ])
        #expect(projects.count == 3)
        #expect(Set(projects.first { $0.path == "/work/app" }!.sessions.map(\.session.id)) == ["root", "source"])
        #expect(projects.first { $0.path == "/work/app/tools" }?.sessions.map(\.session.id) == ["nested"])
        #expect(projects.first { $0.path == "/work/application" }?.sessions.count == 1)
    }

    @Test func hidingSurvivesRescanAndReaddingRestoresChoicesWithoutTouchingFiles() async throws {
        let root = try makeSessionsTempDir("hidden-project")
        defer { removeSessionsTempDir(root) }
        let projectDir = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sourceFile = projectDir.appendingPathComponent("README.md")
        try Data("keep this".utf8).write(to: sourceFile)
        let url = root.appendingPathComponent("projects.json")
        let store = ProjectStore(url: url)
        _ = try await store.rename(projectDir.path, "Kept name")
        _ = try await store.pin(projectDir.path, true)
        _ = try await store.hide(projectDir.path)
        let hidden = try await ProjectStore(url: url).load()
        let live = [session("a", projectDir.path), session("b", projectDir.path + "/src")]
        #expect(ProjectWorkspace.projects(records: hidden.records, snapshot: .empty, live: live).isEmpty)
        let restored = try await store.add(projectDir.path)
        let project = try #require(ProjectWorkspace.projects(records: restored.records, snapshot: .empty, live: live).first)
        #expect(project.sessions.count == 2)
        #expect(project.isPinned && project.name == "Kept name")
        #expect(try Data(contentsOf: sourceFile) == Data("keep this".utf8))
    }

    @Test func mergingLiveAndStoredSessionsKeepsAnnotationsAndRealProcessState() async throws {
        let root = try makeSessionsTempDir("project-sessions")
        defer { removeSessionsTempDir(root) }
        let catalog = SessionCatalog(url: root.appendingPathComponent("sessions.json"))
        var live = session("live", "/work/app", ago: 100, pid: 123)
        live.branch = "feature"
        let old = session("old", "/work/app", agent: .claude, ago: 90_000)
        let process = session("proc-9", "/work/app", agent: .gemini, ago: 10, pid: 456)
        _ = try await catalog.ingest([live, old])
        _ = try await catalog.edit(live.key, expected: .init(), annotation: .init(title: "Review", needsAttention: true,
                                   notes: "Keep notes", artifactDirectory: "/work/app/output"))
        let snapshot = try await catalog.edit(old.key, expected: .init(), annotation: .init(artifactDirectory: "/work/app/output/"))
        let project = try #require(ProjectWorkspace.projects(records: [], snapshot: snapshot, live: [live, process]).first)
        #expect(project.sessions.count == 3)
        #expect(project.pending.first?.displayTitle == "Review")
        #expect(project.pending.first?.annotation.notes == "Keep notes")
        #expect(project.branch == "feature")
        #expect(project.artifacts == ["/work/app/output"])
        #expect(project.entries(recent: true, now: now).count == 2)
        #expect(project.entries(recent: false, now: now).count == 3)
        #expect(project.sessions.first { $0.id == old.key }?.session.isProcessAlive == false)
        #expect(project.sessions.first { $0.id == process.key }?.stored == nil)
        // Recent processes stay visible even when their last transcript activity was yesterday.
        var quiet = live
        quiet.lastActivityAt = now.addingTimeInterval(-90_000)
        let quietProject = try #require(ProjectWorkspace.projects(records: [], snapshot: .empty, live: [quiet]).first)
        #expect(quietProject.entries(recent: true, now: now).count == 1)
    }

    @Test func corruptRegistryAndInvalidEditsLeaveExistingDataUntouched() async throws {
        let root = try makeSessionsTempDir("corrupt-projects")
        defer { removeSessionsTempDir(root) }
        let url = root.appendingPathComponent("projects.json")
        let store = ProjectStore(url: url)
        let original = Data("invalid JSON".utf8)
        try original.write(to: url)
        await #expect(throws: ProjectStoreError.corrupt) { try await store.add(root.path) }
        #expect(try Data(contentsOf: url) == original)
        try FileManager.default.removeItem(at: url)
        _ = try await store.add(root.path)
        let valid = try Data(contentsOf: url)
        await #expect(throws: ProjectStoreError.name) { try await store.rename(root.path, "bad\nname") }
        await #expect(throws: ProjectStoreError.name) { try await store.rename(root.path, "   ") }
        await #expect(throws: ProjectStoreError.folder) { try await store.add(url.path) }
        await #expect(throws: ProjectStoreError.folder) { try await store.add(root.path + "/missing") }
        #expect(try Data(contentsOf: url) == valid)
    }

    @Test func independentStoreInstancesPreserveEachOthersChanges() async throws {
        let root = try makeSessionsTempDir("project-writers")
        defer { removeSessionsTempDir(root) }
        let url = root.appendingPathComponent("projects.json")
        let first = ProjectStore(url: url), second = ProjectStore(url: url)
        _ = try await first.load()
        _ = try await second.load()
        _ = try await first.rename(root.path, "Project")
        _ = try await second.pin(root.path, true)
        let result = try await first.load()
        #expect(result.records.first?.name == "Project")
        #expect(result.records.first?.isPinned == true)
    }
}
