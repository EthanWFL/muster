import Foundation

public struct OpenAIResponsesClient {
    public static let defaultModel = "gpt-4.1-mini"

    public struct Tool {
        public enum Parameter {
            case string, boolean, choices([String])

            fileprivate var schema: [String: Any] {
                switch self {
                case .string: return ["type": "string"]
                case .boolean: return ["type": "boolean"]
                case .choices(let values): return ["type": "string", "enum": values]
                }
            }
        }

        public let name: String
        public let description: String
        public let parameters: [String: Parameter]

        public init(_ name: String, _ description: String, _ parameters: [String: Parameter]) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }

        fileprivate var json: [String: Any] {
            ["type": "function", "name": name, "description": description, "strict": true,
             "parameters": ["type": "object", "properties": parameters.mapValues(\.schema),
                            "required": parameters.keys.sorted(), "additionalProperties": false]]
        }
    }

    public struct Call: Decodable, Sendable {
        public let call_id: String
        public let name: String
        public let arguments: String
    }

    public struct Item: Sendable {
        // Re-send the complete output item, including fields from newer models.
        let data: Data

        public static func user(_ text: String) throws -> Self {
            try Self(["role": "user", "content": text])
        }

        public static func result(for call: Call, output: String) throws -> Self {
            try Self(["type": "function_call_output", "call_id": call.call_id, "output": output])
        }

        fileprivate init(_ json: [String: Any]) throws {
            data = try JSONSerialization.data(withJSONObject: json)
        }
    }

    public struct Response: Sendable {
        public let output: [Item]
        public let calls: [Call]
        public let text: String
    }

    public enum Failure: String, LocalizedError {
        case authorization = "OpenAI rejected the API key or its permissions."
        case model = "This OpenAI model is unavailable or does not support the request."
        case rejected = "OpenAI rejected the request. Try a new conversation."
        case contextLength = "The conversation is too long for this model. Start a new conversation or shorten the message."
        case outputLimit = "The reply reached the output limit. Ask for a shorter answer."
        case quota = "The OpenAI account has no available API quota."
        case rateLimit = "OpenAI is rate limiting requests. Try again shortly."
        case interrupted = "The OpenAI response ended before it was complete."
        case service = "OpenAI could not complete the request. Try again shortly."
        public var errorDescription: String? { rawValue }

        static func http(_ status: Int, code: String?) -> Self {
            if code == "insufficient_quota" || code == "billing_hard_limit_reached" { return .quota }
            if code == "model_not_found" || code == "unsupported_model" { return .model }
            if code == "context_length_exceeded" { return .contextLength }
            if code == "rate_limit_exceeded" { return .rateLimit }
            switch status {
            case 401, 403: return .authorization
            case 400, 422: return .rejected
            case 429: return .rateLimit
            default: return .service
            }
        }
    }

    enum Event {
        case delta(String), completed(Response)
    }

    // OpenAI sends each Responses event as a single JSON data line.
    static func event(from line: String) throws -> Event? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let event = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw Failure.interrupted
        }
        switch event["type"] as? String {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = event["delta"] as? String else { throw Failure.interrupted }
            return .delta(delta)
        case "response.completed":
            guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed",
                  let output = response["output"] as? [[String: Any]] else { throw Failure.interrupted }
            let items = try output.map(Item.init)
            let calls = try zip(output, items).compactMap { item, raw in
                item["type"] as? String == "function_call" ? try JSONDecoder().decode(Call.self, from: raw.data) : nil
            }
            let text = output.filter { $0["type"] as? String == "message" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .compactMap { ($0["text"] ?? $0["refusal"]) as? String }.joined(separator: "\n")
            return .completed(Response(output: items, calls: calls, text: text))
        case "response.incomplete":
            let response = event["response"] as? [String: Any]
            let details = response?["incomplete_details"] as? [String: Any]
            throw details?["reason"] as? String == "max_output_tokens" ? Failure.outputLimit : Failure.interrupted
        case "response.failed", "error":
            let response = event["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any]
            throw Failure.http(500, code: (error?["code"] ?? event["code"]) as? String)
        default: return nil
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    public init() {}

    public func stream(apiKey: String, model: String, input: [Item], instructions: String, tools: [Tool] = [],
                       onDelta: (String) async -> Void) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["model": model, "instructions": instructions,
                                   "stream": true, "store": false, "max_output_tokens": 4096,
                                   "include": ["reasoning.encrypted_content"],
                                   "input": try input.map { try JSONSerialization.jsonObject(with: $0.data) }]
        if !tools.isEmpty {
            body["tools"] = tools.map(\.json)
            body["parallel_tool_calls"] = false
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await Self.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw Failure.service }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes.prefix(16_384) { data.append(byte) }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            throw Failure.http(http.statusCode, code: error?["code"] as? String)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch try Self.event(from: line) {
            case .delta(let text): await onDelta(text)
            case .completed(let result): return result
            case nil: break
            }
        }
        throw Failure.interrupted
    }
}
