import Foundation
import MusterProtocol

/// 声明顺序即严重程度升序，`Comparable` 供队列排序使用
public enum Risk: Int, Codable, Sendable, Comparable {
    case low = 0, medium = 1, high = 2

    public static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }
}

public enum ToolCallStatus: String, Codable, Sendable {
    case pending, allowed, denied, expired
}

public struct ToolCall: Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let agent: AgentKind
    public let tool: String
    public let input: [String: JSONValue]
    public let cwd: String
    public var risk: Risk
    public let requestedAt: Date
    public var status: ToolCallStatus
    /// R5：同一 session 内同一命令重复请求时累计，不刷屏
    public var repeatCount: Int

    public init(
        id: String, sessionID: String, agent: AgentKind, tool: String,
        input: [String: JSONValue], cwd: String, risk: Risk, requestedAt: Date,
        status: ToolCallStatus = .pending, repeatCount: Int = 1
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agent = agent
        self.tool = tool
        self.input = input
        self.cwd = cwd
        self.risk = risk
        self.requestedAt = requestedAt
        self.status = status
        self.repeatCount = repeatCount
    }
}

/// 用户在面板上做出的决策
public enum Decision: Equatable, Sendable {
    case allow
    /// R3：拒绝必须带原因
    case deny(reason: String)
    /// 本会话内同 tool + 同命令前缀不再询问
    case allowSimilar
    /// 超时、app 不可用等；agent 回落到原生提示，绝不等同于允许
    case noDecision
}
