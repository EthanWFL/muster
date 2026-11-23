import Foundation
import MusterCore

@MainActor
struct ChatTools {
    struct Card: Identifiable {
        let id = UUID()
        let session: Session
        let project: String
        let title: String
    }

    static let definitions: [OpenAIResponsesClient.Tool] = [
        .init("find_projects", "Search up to five managed Muster projects by name. Use an empty query to list projects. If truncated is true, tell the user there are additional matches.", ["query": .string]),
        .init("find_sessions", """
              List up to five sessions for a project ID returned by find_projects, newest first. Use query for title keywords.
              from_date and through_date filter last activity by inclusive local calendar dates (YYYY-MM-DD).
              Use an empty string for an unused filter. If truncated is true, tell the user there are additional matches.
              """,
              ["project_id": .string, "agent": .choices(["all"] + AgentKind.allCases.map(\.rawValue)),
               "running_only": .boolean, "query": .string, "from_date": .string, "through_date": .string]),
        .init("propose_open_client", "Show a button for a session ID returned by find_sessions. The user must click it to activate the client.",
              ["session_id": .string])
    ]

    private static let resultLimit = 5
    private var projectIDs: [UUID: String] = [:]
    private var sessionIDs: [UUID: String] = [:]

    mutating func run(_ call: OpenAIResponsesClient.Call, projects: [WorkspaceProject],
                      live: [Session], managedIDs: Set<String>) throws -> (output: String, card: Card?) {
        let invalid = ("{\"error\":\"Invalid tool arguments or unavailable reference.\"}", Optional<Card>.none)
        guard call.arguments.utf8.count <= 4096,
              let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
        else { return invalid }

        switch call.name {
        case "find_projects":
            guard Set(args.keys) == ["query"], let query = args["query"] as? String, query.count <= 160 else { return invalid }
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            let matches = Array(projects.lazy.filter { project in
                words.allSatisfy { project.name.localizedStandardContains($0) }
            }.prefix(Self.resultLimit + 1))
            let rows = matches.prefix(Self.resultLimit).map { project in
                let id = Self.reference(for: project.path, in: &projectIDs)
                return ["id": id.uuidString, "name": Self.label(project.name, fallback: "Project")]
            }
            return try (Self.json(["projects": rows, "truncated": matches.count > Self.resultLimit]), nil)
        case "find_sessions":
            guard Set(args.keys) == ["project_id", "agent", "running_only", "query", "from_date", "through_date"],
                  let id = Self.id(args["project_id"]), let path = projectIDs[id],
                  let agent = args["agent"] as? String, agent == "all" || AgentKind(rawValue: agent) != nil,
                  let running = args["running_only"] as? NSNumber, CFGetTypeID(running) == CFBooleanGetTypeID(),
                  let query = args["query"] as? String, query.count <= 160,
                  let from = args["from_date"] as? String, let through = args["through_date"] as? String,
                  let project = projects.first(where: { $0.path == path }) else { return invalid }
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let format = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day().dateSeparator(.dash)
            let first = Self.day(from, format: format)
            let last = Self.day(through, format: format)
            guard from.isEmpty || first != nil, through.isEmpty || last != nil else { return invalid }
            if let first, let last, first > last { return invalid }
            let end = last.flatMap { calendar.dateInterval(of: .day, for: $0)?.end }
            let active = Dictionary(live.lazy.filter(\.isProcessAlive).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let candidates = words.isEmpty && from.isEmpty && through.isEmpty ? project.entries(recent: true) : project.sessions
            let matches = Array(candidates.lazy.filter { entry in
                let session = entry.session
                guard managedIDs.contains(session.agent.rawValue), agent == "all" || agent == session.agent.rawValue,
                      !running.boolValue || active[entry.id] != nil,
                      first.map({ session.lastActivityAt >= $0 }) ?? true,
                      end.map({ session.lastActivityAt < $0 }) ?? true else { return false }
                guard !words.isEmpty else { return true }
                let title = Self.title(of: entry, in: project)
                return words.allSatisfy { title.localizedStandardContains($0) }
            }.prefix(Self.resultLimit + 1))
            let rows: [[String: Any]] = matches.prefix(Self.resultLimit).map { entry in
                let session = entry.session
                let current = active[entry.id]
                let id = Self.reference(for: entry.id, in: &sessionIDs)
                return ["id": id.uuidString, "title": Self.title(of: entry, in: project),
                        "agent": session.agent.rawValue, "running": current != nil, "can_open": current?.client != nil,
                        "last_active": session.lastActivityAt.ISO8601Format()]
            }
            return try (Self.json(["sessions": rows, "truncated": matches.count > Self.resultLimit]), nil)
        case "propose_open_client":
            guard Set(args.keys) == ["session_id"], let id = Self.id(args["session_id"]), let key = sessionIDs[id],
                  let session = live.first(where: { $0.key == key && $0.isProcessAlive && $0.client != nil }),
                  managedIDs.contains(session.agent.rawValue),
                  let project = projects.first(where: { $0.sessions.contains { $0.id == key } }),
                  let entry = project.sessions.first(where: { $0.id == key }) else { return invalid }
            return ("{\"status\":\"card_shown_user_click_required\"}", Card(session: session, project: project.name, title: entry.displayTitle))
        default:
            return invalid
        }
    }

    private static func reference(for key: String, in references: inout [UUID: String]) -> UUID {
        if let id = references.first(where: { $0.value == key })?.key { return id }
        let id = UUID()
        references[id] = key
        return id
    }

    private static func title(of entry: LibrarySession, in project: WorkspaceProject) -> String {
        let fallback = label(project.name, fallback: entry.session.agent.displayName, excluding: entry.session.id)
        return label(entry.annotation.title, fallback: fallback, excluding: entry.session.id)
    }

    private static func day(_ value: String, format: Date.ISO8601FormatStyle) -> Date? {
        guard value.utf8.count == 10, let date = try? format.parse(value),
              format.format(date) == value else { return nil }
        return date
    }

    private static func id(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }

    private static func label(_ text: String, fallback: String, excluding id: String = "") -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Display titles can contain a path or fall back to a PID or session ID.
        guard !text.isEmpty, !text.contains("/"), (id.isEmpty || !text.contains(id)),
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return fallback }
        return String(text.prefix(120))
    }

    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
