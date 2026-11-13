import Foundation

public enum SessionLibraryScope: String, CaseIterable, Sendable { case recent, history }
public enum SessionLibraryFilter: Hashable, Sendable {
    case all, attention, uncategorized, category(UUID)
}

public struct LibrarySession: Identifiable, Sendable {
    public let session: Session
    public let stored: CatalogSession?
    public init(session: Session, stored: CatalogSession?) { self.session = session; self.stored = stored }
    public var id: String { session.key }
    public var annotation: SessionAnnotation { stored?.annotation ?? SessionAnnotation() }
    public var displayTitle: String {
        stored?.displayTitle ?? ((session.projectName.isEmpty ? session.agent.displayName : session.projectName)
            + " · " + (session.pid.map { "PID \($0)" } ?? String(session.id.prefix(8))))
    }
}

public struct SessionLibraryBrowser: Sendable {
    public var scope: SessionLibraryScope
    public var filter: SessionLibraryFilter
    public var query: String

    public init(scope: SessionLibraryScope = .recent, filter: SessionLibraryFilter = .all, query: String = "") {
        self.scope = scope; self.filter = filter; self.query = query
    }

    public func entries(snapshot: SessionCatalogSnapshot, live: [Session], now: Date = Date()) -> [LibrarySession] {
        var items = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, LibrarySession(session: $0.session, stored: $0)) })
        for session in live {
            guard scope == .recent || session.hasTranscript else { continue }
            items[session.key] = LibrarySession(session: session, stored: items[session.key]?.stored)
        }
        let names = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0.name) })
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.values.filter { entry in
            if scope == .recent && !entry.session.isProcessAlive
                && entry.session.lastActivityAt < now.addingTimeInterval(-SessionPolicy.defaultRetention) { return false }
            switch filter {
            case .all: break
            case .attention: guard entry.annotation.needsAttention else { return false }
            case .uncategorized: guard entry.annotation.categoryID == nil else { return false }
            case .category(let id): guard entry.annotation.categoryID == id else { return false }
            }
            guard !words.isEmpty else { return true }
            let text = [entry.displayTitle, entry.session.cwd, entry.session.agent.displayName, entry.session.id,
                        entry.session.branch ?? "", entry.session.pid.map(String.init) ?? "",
                        entry.annotation.categoryID.flatMap { names[$0] } ?? "", entry.annotation.notes,
                        entry.annotation.artifactDirectory ?? ""].joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }.sorted {
            $0.session.lastActivityAt != $1.session.lastActivityAt
                ? $0.session.lastActivityAt > $1.session.lastActivityAt : $0.id < $1.id
        }
    }
}
