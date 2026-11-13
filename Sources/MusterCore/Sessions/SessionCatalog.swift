import Foundation

public struct SessionAnnotation: Codable, Equatable, Sendable {
    public var title: String
    public var categoryID: UUID?
    public var needsAttention: Bool
    public var notes: String
    public var artifactDirectory: String?

    public init(title: String = "", categoryID: UUID? = nil, needsAttention: Bool = false,
                notes: String = "", artifactDirectory: String? = nil) {
        self.title = title; self.categoryID = categoryID; self.needsAttention = needsAttention
        self.notes = notes; self.artifactDirectory = artifactDirectory
    }

    /// Undo only fields written by this change; preserve independent later edits.
    fileprivate func undoing(before: Self, after: Self) throws -> Self {
        var result = self
        func revert<T: Equatable>(_ key: WritableKeyPath<Self, T>) throws {
            guard before[keyPath: key] != after[keyPath: key] else { return }
            guard result[keyPath: key] == after[keyPath: key] else { throw SessionCatalogError.conflict }
            result[keyPath: key] = before[keyPath: key]
        }
        try revert(\.title); try revert(\.categoryID); try revert(\.needsAttention)
        try revert(\.notes); try revert(\.artifactDirectory)
        return result
    }
}

public struct SessionCategory: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct CatalogSession: Identifiable, Codable, Equatable, Sendable {
    public let sessionID: String
    public let agent: AgentKind
    public var cwd: String
    public var startedAt: Date
    public var lastActivityAt: Date
    public var annotation: SessionAnnotation
    public var id: String { agent.rawValue + ":" + sessionID }
    public var displayTitle: String {
        annotation.title.isEmpty ? ((cwd as NSString).lastPathComponent.isEmpty ? agent.displayName : (cwd as NSString).lastPathComponent)
            + " · " + String(sessionID.prefix(8)) : annotation.title
    }
    /// Process identities are deliberately not persisted. A current scan supplies live state.
    public var session: Session {
        Session(id: sessionID, agent: agent, cwd: cwd, startedAt: startedAt,
                lastActivityAt: lastActivityAt, state: .ended)
    }

    fileprivate init(_ session: Session) {
        sessionID = session.id; agent = session.agent; cwd = session.cwd
        startedAt = session.startedAt; lastActivityAt = session.lastActivityAt
        annotation = SessionAnnotation()
    }
}

public enum CatalogChangeKind: String, Codable, Sendable {
    case details = "Session details changed"
    case createCategory = "Category created"
    case renameCategory = "Category renamed"
    case deleteCategory = "Category deleted"
}

public struct CatalogChangeSummary: Identifiable, Sendable {
    public let id: UUID
    public let kind: CatalogChangeKind
    public let date: Date
}

public struct SessionCatalogSnapshot: Sendable {
    public let revision: UInt64
    public let sessions: [CatalogSession]
    public let categories: [SessionCategory]
    public let lastChange: CatalogChangeSummary?
    public static let empty = Self(revision: 0, sessions: [], categories: [], lastChange: nil)
}

public enum SessionCatalogError: String, LocalizedError {
    case corrupt = "The session library could not be read. Its files have been left unchanged."
    case invalid = "Check the title, notes and folder path before saving."
    case categoryName = "Use a unique category name of 1–64 characters."
    case missing = "This session or category is no longer available. Reload the library."
    case conflict = "This item changed after you opened it. Reload it before applying changes."
    case categoryInUse = "This category now contains other sessions. Undo their assignments first."
    case noUndo = "No matching change is available to undo."
    public var errorDescription: String? { rawValue }
}

/// Serializes metadata edits and imports, and persists a bounded undo journal with them.
/// All mutations read the latest file under a lock shared by other Muster instances.
public actor SessionCatalog {
    public let url: URL
    private struct AnnotationDelta: Codable {
        let key: String
        let before: SessionAnnotation
        let after: SessionAnnotation
    }
    private struct CategoryDelta: Codable {
        let id: UUID
        let before: SessionCategory?
        let after: SessionCategory?
    }
    private struct Change: Codable {
        let id: UUID
        let kind: CatalogChangeKind
        let date: Date
        var annotations: [AnnotationDelta] = []
        var category: CategoryDelta?
    }
    private struct State: Codable {
        var schema = 1
        var revision: UInt64 = 0
        var sessions: [String: CatalogSession] = [:]
        var categories: [SessionCategory] = []
        var changes: [Change] = []
    }

    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Muster/session-library.json")) { self.url = url }

    public func load() throws -> SessionCatalogSnapshot { try transact { _ in false } }

    public func ingest(_ sessions: [Session]) throws -> SessionCatalogSnapshot {
        try transact { state in
            try Task.checkCancellation()
            var changed = false
            for session in sessions where session.hasTranscript && !session.id.isEmpty
                && AgentRegistry.agent(session.agent.rawValue)?.tracksActivity == true {
                try Task.checkCancellation()
                if var existing = state.sessions[session.key] {
                    let old = existing
                    existing.startedAt = min(existing.startedAt, session.startedAt)
                    if session.lastActivityAt >= existing.lastActivityAt {
                        existing.lastActivityAt = session.lastActivityAt
                        if !session.cwd.isEmpty { existing.cwd = session.cwd }
                    }
                    if old != existing { state.sessions[session.key] = existing; changed = true }
                } else { state.sessions[session.key] = CatalogSession(session); changed = true }
            }
            return changed
        }
    }

    public func edit(_ key: String, expected: SessionAnnotation, annotation: SessionAnnotation) throws -> SessionCatalogSnapshot {
        try transact { state in
            guard var entry = state.sessions[key] else { throw SessionCatalogError.missing }
            guard entry.annotation == expected else { throw SessionCatalogError.conflict }
            guard annotation != expected else { return false }
            entry.annotation = annotation
            state.sessions[key] = entry
            record(Change(id: UUID(), kind: .details, date: Date(),
                          annotations: [.init(key: key, before: expected, after: annotation)]), in: &state)
            return true
        }
    }

    public func createCategory(named name: String) throws -> SessionCatalogSnapshot {
        try transact { state in
            let category = SessionCategory(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            state.categories.append(category)
            record(Change(id: UUID(), kind: .createCategory, date: Date(),
                          category: .init(id: category.id, before: nil, after: category)), in: &state)
            return true
        }
    }

    public func renameCategory(_ expected: SessionCategory, name: String) throws -> SessionCatalogSnapshot {
        try transact { state in
            guard let index = state.categories.firstIndex(where: { $0.id == expected.id }) else { throw SessionCatalogError.missing }
            guard state.categories[index] == expected else { throw SessionCatalogError.conflict }
            var updated = expected
            updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard updated != expected else { return false }
            state.categories[index] = updated
            record(Change(id: UUID(), kind: .renameCategory, date: Date(),
                          category: .init(id: expected.id, before: expected, after: updated)), in: &state)
            return true
        }
    }

    public func deleteCategory(_ expected: SessionCategory) throws -> SessionCatalogSnapshot {
        try transact { state in
            guard let index = state.categories.firstIndex(where: { $0.id == expected.id }) else { throw SessionCatalogError.missing }
            guard state.categories[index] == expected else { throw SessionCatalogError.conflict }
            state.categories.remove(at: index)
            var change = Change(id: UUID(), kind: .deleteCategory, date: Date(),
                                category: .init(id: expected.id, before: expected, after: nil))
            for key in Array(state.sessions.keys) {
                guard var entry = state.sessions[key], entry.annotation.categoryID == expected.id else { continue }
                let before = entry.annotation
                entry.annotation.categoryID = nil
                state.sessions[key] = entry
                change.annotations.append(.init(key: key, before: before, after: entry.annotation))
            }
            record(change, in: &state)
            return true
        }
    }

    public func undo(_ changeID: UUID) throws -> SessionCatalogSnapshot {
        try transact { state in
            guard let change = state.changes.last, change.id == changeID else { throw SessionCatalogError.noUndo }
            if let delta = change.category {
                guard state.categories.first(where: { $0.id == delta.id }) == delta.after else { throw SessionCatalogError.conflict }
                if delta.before == nil, state.sessions.values.contains(where: { $0.annotation.categoryID == delta.id }) {
                    throw SessionCatalogError.categoryInUse
                }
                state.categories.removeAll { $0.id == delta.id }
                if let before = delta.before { state.categories.append(before) }
            }
            for delta in change.annotations {
                guard var entry = state.sessions[delta.key] else { throw SessionCatalogError.conflict }
                entry.annotation = try entry.annotation.undoing(before: delta.before, after: delta.after)
                state.sessions[delta.key] = entry
            }
            state.changes.removeLast()
            return true
        }
    }

    private func record(_ change: Change, in state: inout State) {
        state.changes.append(change)
        state.changes = Array(state.changes.suffix(50))
    }

    private func validate(_ state: State) throws {
        guard state.schema == 1, state.revision < UInt64.max else { throw SessionCatalogError.corrupt }
        let ids = Set(state.categories.map(\.id))
        let names = state.categories.map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        guard ids.count == state.categories.count, Set(names).count == names.count,
              state.categories.allSatisfy({ singleLine($0.name, limit: 64) && !$0.name.isEmpty }) else { throw SessionCatalogError.categoryName }
        for (key, session) in state.sessions {
            let value = session.annotation
            guard key == session.id, !session.sessionID.isEmpty, !session.sessionID.hasPrefix("proc-") else { throw SessionCatalogError.corrupt }
            guard singleLine(value.title, limit: 160), value.notes.count <= 8_000, !value.notes.contains("\0"),
                  value.categoryID.map(ids.contains) ?? true,
                  value.artifactDirectory.map({ $0.hasPrefix("/") && !$0.contains("\0") && !$0.contains("\n") }) ?? true
            else { throw SessionCatalogError.invalid }
        }
    }

    private func singleLine(_ text: String, limit: Int) -> Bool {
        text.count <= limit && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
            && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func transact(_ mutation: (inout State) throws -> Bool) throws -> SessionCatalogSnapshot {
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
            try validate(state)
        } catch { throw SessionCatalogError.corrupt }
        if try mutation(&state) {
            try validate(state)
            state.revision += 1
            let temporary = directory.appendingPathComponent(".session-library-" + UUID().uuidString)
            defer { try? fm.removeItem(at: temporary) }
            let data = try JSONEncoder().encode(state)
            guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let current = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            guard current == original else { throw SessionCatalogError.conflict }
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
        }
        return SessionCatalogSnapshot(revision: state.revision,
            sessions: state.sessions.values.sorted { $0.lastActivityAt != $1.lastActivityAt ? $0.lastActivityAt > $1.lastActivityAt : $0.id < $1.id },
            categories: state.categories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            lastChange: state.changes.last.map { .init(id: $0.id, kind: $0.kind, date: $0.date) })
    }
}
