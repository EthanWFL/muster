import Foundation

/// Thresholds for the session state machine. Named constants, overridable per instance for tests.
public struct SessionPolicy: Equatable, Sendable {
    /// PRD 5.3: only sessions from the last 24h are kept.
    public static let defaultRetention: TimeInterval = 24 * 60 * 60
    /// A disk-only session whose transcript changed within this window counts as `running`.
    public static let defaultDiskRunningWindow: TimeInterval = 30
    /// `ended` when there was no activity for this long (the "N minutes" of IMPLEMENTATION M1).
    public static let defaultEndedAfterInactivity: TimeInterval = 30 * 60
    /// Number of recent tool-call summaries kept per session.
    public static let defaultMaxToolSummaries = 3
    /// Summaries are cut to this many characters before being stored.
    public static let defaultMaxSummaryLength = 200

    public var retention: TimeInterval
    public var diskRunningWindow: TimeInterval
    public var endedAfterInactivity: TimeInterval
    public var maxToolSummaries: Int
    public var maxSummaryLength: Int

    public init(
        retention: TimeInterval = SessionPolicy.defaultRetention,
        diskRunningWindow: TimeInterval = SessionPolicy.defaultDiskRunningWindow,
        endedAfterInactivity: TimeInterval = SessionPolicy.defaultEndedAfterInactivity,
        maxToolSummaries: Int = SessionPolicy.defaultMaxToolSummaries,
        maxSummaryLength: Int = SessionPolicy.defaultMaxSummaryLength
    ) {
        self.retention = retention
        self.diskRunningWindow = diskRunningWindow
        self.endedAfterInactivity = endedAfterInactivity
        self.maxToolSummaries = maxToolSummaries
        self.maxSummaryLength = maxSummaryLength
    }

    public static let standard = SessionPolicy()
}

/// A live event reported by an agent hook. Carries no conversation text;
/// `summary` is a short description of a tool call (for example "Bash: ls").
public struct SessionHookEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case started
        case toolCall(summary: String)
        /// Waiting for the user (approval pending).
        case waiting
        /// Agent finished its turn.
        case idle
        case ended
    }

    public var sessionID: String
    public var agent: AgentKind
    public var cwd: String?
    public var pid: Int32?
    public var pidStartTime: Date?
    public var kind: Kind
    public var at: Date

    public init(
        sessionID: String, agent: AgentKind = .claude, cwd: String? = nil,
        pid: Int32? = nil, pidStartTime: Date? = nil, kind: Kind, at: Date
    ) {
        self.sessionID = sessionID
        self.agent = agent
        self.cwd = cwd
        self.pid = pid
        self.pidStartTime = pidStartTime
        self.kind = kind
        self.at = at
    }
}
