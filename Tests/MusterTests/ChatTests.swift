import AppKit
import Testing
@testable import MusterCore
@testable import Muster

@Suite @MainActor struct ChatTests {
    private typealias Client = OpenAIResponsesClient

    @Test func composerPlaceholderFollowsInputMethodComposition() throws {
        let scroll = ChatInputTextView.scrollableTextView()
        let input = try #require(scroll.documentView as? ChatInputTextView)
        let selection = NSRange(location: NSNotFound, length: 0)
        #expect(input.showsPlaceholder)
        input.setMarkedText("dang", selectedRange: NSRange(location: 4, length: 0), replacementRange: selection)
        #expect(input.hasMarkedText() && !input.showsPlaceholder)
        input.insertText("", replacementRange: input.markedRange())
        #expect(input.showsPlaceholder)
        input.setMarkedText("dangqian", selectedRange: NSRange(location: 8, length: 0), replacementRange: selection)
        input.insertText("当前", replacementRange: input.markedRange())
        #expect(input.string == "当前" && !input.showsPlaceholder)
        input.string = ""
        #expect(input.showsPlaceholder)
    }

    @Test func streamsTextAndPreservesCompletedToolItems() throws {
        let delta = try Client.event(from: #"data: {"type":"response.output_text.delta","delta":"你好"}"#)
        let event = try #require(delta)
        guard case .delta(let text) = event else { Issue.record("Expected a text delta"); return }
        #expect(text == "你好")
        let completed = try Client.event(from: #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","encrypted_content":"opaque"},{"type":"function_call","call_id":"call_a","name":"find_projects","arguments":"{\"query\":\"Muster\"}"}]}}"#)
        let reply = try #require(completed)
        guard case .completed(let complete) = reply else { Issue.record("Expected a completed response"); return }
        #expect(try Self.object(complete.output[0].data)["encrypted_content"] as? String == "opaque")
        let call = try #require(complete.calls.first)
        #expect(call.name == "find_projects")
        let item = try Client.Item.result(for: call, output: "projects")
        #expect(try Self.object(item.data)["call_id"] as? String == "call_a")
        #expect(throws: Client.Failure.interrupted) {
            try Client.event(from: #"data: {"type":"response.incomplete"}"#)
        }
        #expect(Client.Failure.http(429, code: "insufficient_quota") == .quota)
        #expect(Client.Failure.http(429, code: nil) == .rateLimit)
        #expect(Client.Failure.http(401, code: "invalid_api_key") == .authorization)
        #expect(Client.Failure.http(400, code: nil) == .rejected)
        #expect(Client.Failure.http(404, code: "model_not_found") == .model)
        #expect(Client.Failure.http(400, code: "context_length_exceeded") == .contextLength)
        #expect(throws: Client.Failure.rateLimit) {
            try Client.event(from: #"data: {"type":"error","code":"rate_limit_exceeded"}"#)
        }
        #expect(throws: Client.Failure.outputLimit) {
            try Client.event(from: #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#)
        }
    }

    @Test func toolResultsUseTemporaryIDsAndCanOnlyProposeManagedLiveSessions() throws {
        let client = SessionClient(name: "Terminal", bundlePath: "/Applications/Terminal.app")
        let session = Session(id: "private-session-id", agent: .codex, cwd: "/private/muster", pid: 42,
                              startedAt: Date(), client: client)
        let unmanaged = Session(id: "hidden", agent: .pi, cwd: session.cwd, pid: 44, startedAt: Date(), client: client)
        let live = [session, unmanaged]
        let projects = ProjectWorkspace.projects(records: [], snapshot: .empty, live: live)
        var tools = ChatTools()
        let search = try Self.call("find_projects", ["query": "muster"])
        let projectResult = try tools.run(search, projects: projects, live: live, managedIDs: ["codex"])
        let projectID = try Self.reference(projectResult.output, field: "projects")
        #expect(!projectResult.output.contains(session.cwd))
        let lookup = try Self.sessionLookup(projectID, running: true)
        let sessionResult = try tools.run(lookup, projects: projects, live: live, managedIDs: ["codex"])
        let sessionID = try Self.reference(sessionResult.output, field: "sessions")
        #expect(!sessionResult.output.contains(session.id))
        #expect(!sessionResult.output.contains("\"pi\""))
        let proposal = try Self.call("propose_open_client", ["session_id": sessionID])
        let result = try tools.run(proposal, projects: projects, live: live, managedIDs: ["codex"])
        #expect(result.card?.session.key == session.key)
        #expect(result.output.contains("user_click_required"))
        #expect(try tools.run(proposal, projects: projects, live: [], managedIDs: ["codex"]).card == nil)
        #expect(try tools.run(proposal, projects: projects, live: live, managedIDs: ["pi"]).card == nil)
        let forged = try Self.call("propose_open_client", ["session_id": session.key])
        #expect(try tools.run(forged, projects: projects, live: live, managedIDs: ["codex"]).card == nil)
        let badBool = try Self.sessionLookup(projectID, running: 1)
        #expect(try tools.run(badBool, projects: projects, live: live, managedIDs: ["codex"]).output.contains("Invalid"))
    }

    @Test func filtersHistoricalSessionsByTitleAndInclusiveLocalDayBeforeLimiting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = SessionCatalog(url: directory.appendingPathComponent("catalog.json"))
        let format = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash)
        let start = try format.parse("2025-03-09")
        let end = try format.parse("2025-03-10")
        let path = "/private/muster"
        let entries = (0..<6).map { index in
            Session(id: "session-\(index)", agent: .codex, cwd: path, startedAt: start.addingTimeInterval(Double(index)))
        } + [Session(id: "outside", agent: .codex, cwd: path, startedAt: end),
             Session(id: "before", agent: .codex, cwd: path, startedAt: start.addingTimeInterval(-1)),
             Session(id: "unrelated", agent: .codex, cwd: path, startedAt: end.addingTimeInterval(-1))]
        var snapshot = try await catalog.ingest(entries)
        for entry in entries {
            let title = entry.id == "unrelated" ? "Other work" : "Release Café \(entry.id.last!)"
            snapshot = try await catalog.edit(entry.key, expected: .init(), annotation: .init(title: title))
        }
        let projects = ProjectWorkspace.projects(records: [], snapshot: snapshot, live: [])
        var tools = ChatTools()
        let project = try tools.run(Self.call("find_projects", ["query": "Muster"]), projects: projects, live: [], managedIDs: ["codex"])
        let id = try Self.reference(project.output, field: "projects")
        let lookup = try Self.sessionLookup(id, query: "release cafe", from: "2025-03-09", through: "2025-03-09")
        let result = try tools.run(lookup, projects: projects, live: [], managedIDs: ["codex"])
        let json = try Self.object(Data(result.output.utf8))
        let rows = try #require(json["sessions"] as? [[String: Any]])
        #expect(rows.compactMap { $0["title"] as? String } == (1...5).reversed().map { "Release Café \($0)" })
        #expect(json["truncated"] as? Bool == true)
        let boundary = try Self.sessionLookup(id, query: "cafe 0", from: "2025-03-09", through: "2025-03-09")
        let boundaryResult = try tools.run(boundary, projects: projects, live: [], managedIDs: ["codex"])
        let boundaryJSON = try Self.object(Data(boundaryResult.output.utf8))
        #expect((boundaryJSON["sessions"] as? [[String: Any]])?.first?["title"] as? String == "Release Café 0")
        #expect(boundaryJSON["truncated"] as? Bool == false)
        for date in ["2025-02-30", "2025-3-09", "2025-03-10"] {
            let invalid = try Self.sessionLookup(id, from: date, through: "2025-03-09")
            #expect(try tools.run(invalid, projects: projects, live: [], managedIDs: ["codex"]).output.contains("Invalid"))
        }
    }

    @Test func continuesToolCallsUpToTheLimitAndCanCancel() async throws {
        let panel = PanelModel(detectInstalledAgents: { [] })
        let call = try Self.call("find_projects", ["query": "muster"])
        var toolCounts: [Int] = []
        let chat = ChatModel { _, _, input, _, tools, delta in
            toolCounts.append(tools.count)
            let round = toolCounts.count
            #expect(input.count == 2 * round - 1)
            if round > 1 {
                let result = try Self.object(try #require(input.last).data)
                #expect(result["call_id"] as? String == call.call_id)
            }
            if !tools.isEmpty {
                let output = try Client.event(from: #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","call_id":"call_a","name":"find_projects","arguments":"{\"query\":\"muster\"}"}]}}"#)
                guard case .completed(let response) = output else { throw Client.Failure.interrupted }
                return response
            }
            await delta("Done")
            return Client.Response(output: [], calls: [], text: "Done")
        }
        chat.draft = "Find Muster"
        chat.start(panel: panel, model: "test", key: "unused")
        await chat.task?.value
        #expect(toolCounts == [3, 3, 3, 0])
        #expect(chat.turns.first?.reply == "Done")
        #expect(!chat.isGenerating)

        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let cancelled = ChatModel { _, _, _, _, _, delta in
            await delta("Partial")
            startSignal.yield(())
            try await Task.sleep(for: .seconds(60))
            return Client.Response(output: [], calls: [], text: "Too late")
        }
        cancelled.draft = "Test cancellation"
        cancelled.start(panel: panel, model: "test", key: "unused")
        let task = cancelled.task
        var signal = started.makeAsyncIterator()
        _ = await signal.next()
        cancelled.stop()
        await task?.value
        #expect(!cancelled.isGenerating)
        #expect(cancelled.turns.first?.reply == "Partial")
        #expect(cancelled.turns.first?.notice == L10n.t("Generation stopped."))
    }

    @Test func retriesOnlyTheLastFailedTurnWithoutLosingDraftOrReplayingPartialReply() async throws {
        let panel = PanelModel(detectInstalledAgents: { [] })
        var prompts: [[String]] = []
        let chat = ChatModel { _, _, input, _, _, delta in
            prompts.append(try input.compactMap { try Self.object($0.data)["content"] as? String })
            if prompts.count == 2 {
                await delta("Partial")
                throw Client.Failure.rateLimit
            }
            return Client.Response(output: [], calls: [], text: "Done")
        }
        chat.draft = "First"
        chat.start(panel: panel, model: "test", key: "unused")
        await chat.task?.value
        chat.draft = "Retry me"
        chat.start(panel: panel, model: "test", key: "unused")
        await chat.task?.value
        let failed = try #require(chat.turns.last)
        #expect(failed.notice == L10n.t(Client.Failure.rateLimit.rawValue))
        #expect(failed.reply == "Partial")
        chat.draft = "Still typing"
        chat.start(panel: panel, model: "test", key: "unused", retrying: chat.turns.first?.id)
        #expect(!chat.isGenerating)
        chat.start(panel: panel, model: "test", key: "unused", retrying: failed.id)
        await chat.task?.value
        #expect(prompts == [["First"], ["First", "Retry me"], ["First", "Retry me"]])
        #expect(chat.turns.map(\.prompt) == ["First", "Retry me"])
        #expect(chat.turns.last?.reply == "Done")
        #expect(chat.turns.last?.notice == nil)
        #expect(chat.draft == "Still typing")
    }

    private static func sessionLookup(_ id: String, running: Any = false, query: String = "",
                                      from: String = "", through: String = "") throws -> Client.Call {
        try call("find_sessions", ["project_id": id, "agent": "all", "running_only": running,
                                   "query": query, "from_date": from, "through_date": through])
    }

    private static func call(_ name: String, _ args: [String: Any]) throws -> Client.Call {
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: ["call_id": "call_a", "name": name, "arguments": arguments])
        return try JSONDecoder().decode(Client.Call.self, from: data)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func reference(_ output: String, field: String) throws -> String {
        let rows = try Self.object(Data(output.utf8))[field] as? [[String: Any]]
        return try #require(rows?.first?["id"] as? String)
    }
}
