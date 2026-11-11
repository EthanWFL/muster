import Foundation

public enum Wire {
    /// 当前协议版本；未知版本一律按 no_decision 处理
    public static let version = 1
    /// 单行上限 1 MB，超长直接断开
    public static let maxLineBytes = 1_048_576
    /// hook 端上报 content 类字段的截断上限
    public static let maxContentBytes = 64 * 1024
    /// app 侧默认审批超时（以 M0 结论为准）
    public static let defaultTTLms = 90_000
}

public enum WireDecision: String, Codable, Sendable {
    case allow
    case deny
    case allowSimilar = "allow_similar"
    case noDecision = "no_decision"
}

/// hook → app
public struct WireRequest: Codable, Equatable, Sendable {
    public var v: Int
    public var type: String
    public var id: String
    public var session: String
    public var agent: String
    public var tool: String
    public var input: [String: JSONValue]
    public var cwd: String
    public var ts: Int
    public var truncated: Bool?
    /// Agent process (not the short-lived hook process), so the panel can find its terminal.
    public var pid: Int32?
    /// Epoch seconds, guards against PID reuse.
    public var pidStartedAt: Double?

    public init(
        id: String, session: String, agent: String, tool: String,
        input: [String: JSONValue], cwd: String, ts: Int, truncated: Bool? = nil,
        pid: Int32? = nil, pidStartedAt: Double? = nil
    ) {
        self.v = Wire.version
        self.type = "request"
        self.id = id
        self.session = session
        self.agent = agent
        self.tool = tool
        self.input = input
        self.cwd = cwd
        self.ts = ts
        self.truncated = truncated
        self.pid = pid
        self.pidStartedAt = pidStartedAt
    }
}

/// app → hook
public struct WireResponse: Codable, Equatable, Sendable {
    public var v: Int
    public var type: String
    public var id: String
    public var decision: WireDecision
    public var reason: String?
    public var ttlMs: Int?

    enum CodingKeys: String, CodingKey {
        case v, type, id, decision, reason
        case ttlMs = "ttl_ms"
    }

    public init(id: String, decision: WireDecision, reason: String? = nil, ttlMs: Int? = nil) {
        self.v = Wire.version
        self.type = "decision"
        self.id = id
        self.decision = decision
        self.reason = reason
        self.ttlMs = ttlMs
    }
}

public enum WireCodecError: Error, Equatable {
    case lineTooLong
    case invalidUTF8OrJSON
}

/// NDJSON 编解码：一行一条消息，以 `\n` 结尾。
public enum WireCodec {
    public static func encodeLine<T: Encodable>(_ message: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try enc.encode(message)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: Data) throws -> T {
        guard line.count <= Wire.maxLineBytes else { throw WireCodecError.lineTooLong }
        do {
            return try JSONDecoder().decode(type, from: line)
        } catch {
            throw WireCodecError.invalidUTF8OrJSON
        }
    }
}
