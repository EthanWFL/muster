import Foundation

/// User choices only. Sessions and annotations remain owned by SessionCatalog.
public struct ProjectRecord: Codable, Equatable, Sendable, Identifiable {
    public let path: String
    public var name = ""
    public var isPinned = false
    public var isHidden = false
    public let addedAt: Date
    public var id: String { path }

    public init(path: String, addedAt: Date = Date()) {
        self.path = path
        self.addedAt = addedAt
    }
}

public struct WorkspaceProject: Identifiable, Sendable {
    public let path: String
    public let record: ProjectRecord?
    public let sessions: [LibrarySession]
    public var id: String { path }
    public var name: String {
        if let name = record?.name, !name.isEmpty { return name }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
    public var isPinned: Bool { record?.isPinned == true }
    public var pending: [LibrarySession] { sessions.filter { $0.annotation.needsAttention } }
    public var lastActivity: Date? { sessions.first?.session.lastActivityAt }
    public var branch: String? {
        sessions.first { ProjectWorkspace.path($0.session.cwd) == path && $0.session.branch != nil }?.session.branch
    }
    public var artifacts: [String] {
        Array(Set(sessions.compactMap { $0.annotation.artifactDirectory }.compactMap(ProjectWorkspace.path))).sorted()
    }

    public func entries(recent: Bool, now: Date = Date()) -> [LibrarySession] {
        sessions.filter { !recent || $0.session.isProcessAlive || $0.session.lastActivityAt >= now.addingTimeInterval(-SessionPolicy.defaultRetention) }
    }
}

public enum ProjectWorkspace {
    /// Lexical normalization avoids filesystem probes and authorization prompts during discovery.
    public static func path(_ value: String) -> String? {
        guard value.hasPrefix("/"), !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    public static func projects(records: [ProjectRecord], snapshot: SessionCatalogSnapshot,
                                live: [Session], agentIDs: Set<String>? = nil) -> [WorkspaceProject] {
        var entries = Dictionary(uniqueKeysWithValues: snapshot.sessions.filter { agentIDs?.contains($0.agent.rawValue) ?? true }.map {
            ($0.id, LibrarySession(session: $0.session, stored: $0))
        })
        for session in live where agentIDs?.contains(session.agent.rawValue) ?? true {
            entries[session.key] = LibrarySession(session: session, stored: entries[session.key]?.stored)
        }
        let choices = Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })
        // Explicit nested projects win over their parent. Hidden roots still own their sessions,
        // so a rescan cannot immediately reintroduce a removed project under a child directory.
        let roots = records.map(\.path).sorted { $0.count > $1.count }
        var groups: [String: [LibrarySession]] = [:]
        for entry in entries.values {
            guard let cwd = path(entry.session.cwd) else { continue }
            let owner = roots.first { cwd == $0 || cwd.hasPrefix($0 == "/" ? "/" : $0 + "/") } ?? cwd
            groups[owner, default: []].append(entry)
        }
        return Set(groups.keys).union(choices.keys).compactMap { path -> WorkspaceProject? in
            guard choices[path]?.isHidden != true else { return nil }
            let sessions = (groups[path] ?? []).sorted {
                $0.session.lastActivityAt != $1.session.lastActivityAt
                    ? $0.session.lastActivityAt > $1.session.lastActivityAt : $0.id < $1.id
            }
            return WorkspaceProject(path: path, record: choices[path], sessions: sessions)
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            let left = $0.lastActivity ?? $0.record?.addedAt ?? .distantPast
            let right = $1.lastActivity ?? $1.record?.addedAt ?? .distantPast
            return left != right ? left > right : $0.path < $1.path
        }
    }
}

public struct ProjectSnapshot: Sendable {
    public let revision: UInt64
    public let records: [ProjectRecord]
    public static let empty = Self(revision: 0, records: [])
}

public enum ProjectStoreError: String, LocalizedError {
    case corrupt = "The project list could not be read. Its file has been left unchanged."
    case folder = "Choose an existing project folder."
    case name = "Use a project name of 1–80 characters."
    case conflict = "The project list changed. Reload it before trying again."
    public var errorDescription: String? { rawValue }
}

/// Small, private registry; no project files, agent records or conversation text are written.
public actor ProjectStore {
    public let url: URL
    private struct State: Codable {
        var schema = 1
        var revision: UInt64 = 0
        var records: [ProjectRecord] = []
    }

    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Muster/projects.json")) { self.url = url }

    public func load() throws -> ProjectSnapshot { try transact { _ in false } }

    public func add(_ path: String) throws -> ProjectSnapshot {
        var directory: ObjCBool = false
        guard let path = ProjectWorkspace.path(path),
              FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue
        else { throw ProjectStoreError.folder }
        return try update(path) { $0.isHidden = false }
    }

    public func pin(_ path: String, _ value: Bool) throws -> ProjectSnapshot {
        try update(path) { $0.isPinned = value }
    }

    public func rename(_ path: String, _ name: String) throws -> ProjectSnapshot {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, validName(name) else { throw ProjectStoreError.name }
        return try update(path) { $0.name = name }
    }

    public func hide(_ path: String) throws -> ProjectSnapshot {
        try update(path) { $0.isHidden = true }
    }

    private func update(_ path: String, _ change: (inout ProjectRecord) -> Void) throws -> ProjectSnapshot {
        guard let path = ProjectWorkspace.path(path) else { throw ProjectStoreError.folder }
        return try transact { state in
            if let index = state.records.firstIndex(where: { $0.path == path }) {
                let old = state.records[index]
                change(&state.records[index])
                return old != state.records[index]
            }
            var record = ProjectRecord(path: path)
            change(&record)
            state.records.append(record)
            return true
        }
    }

    private func validName(_ value: String) -> Bool {
        value.count <= 80 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func transact(_ mutation: (inout State) throws -> Bool) throws -> ProjectSnapshot {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        let original = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        var state: State
        do {
            state = try original.map { try JSONDecoder().decode(State.self, from: $0) } ?? State()
            guard state.schema == 1, state.revision < UInt64.max,
                  Set(state.records.map(\.path)).count == state.records.count,
                  state.records.allSatisfy({ ProjectWorkspace.path($0.path) == $0.path && validName($0.name) })
            else { throw ProjectStoreError.corrupt }
        } catch { throw ProjectStoreError.corrupt }
        if try mutation(&state) {
            state.revision += 1
            let temporary = directory.appendingPathComponent(".projects-" + UUID().uuidString)
            defer { try? fm.removeItem(at: temporary) }
            guard fm.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(state),
                                attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let current = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            guard current == original else { throw ProjectStoreError.conflict }
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
        }
        return ProjectSnapshot(revision: state.revision, records: state.records)
    }
}
