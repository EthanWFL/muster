import Foundation
import MusterProtocol

public enum ApprovalError: Error, Equatable, Sendable {
    /// 没有这个 id（从未提交、已被取消，或已被清出历史）
    case notFound
    /// 已经是 allowed/denied/expired，状态只能前进一次
    case notPending
    /// R3：拒绝原因为空或全是空白
    case emptyReason
    /// 高危命令、代码执行类前缀等不提供「允许同类」
    case similarNotEligible
}

public enum SubmitOutcome: Sendable, Equatable {
    /// 新增一行
    case queued(ToolCall)
    /// R5：并入已有的待处理行，`repeatCount` 已加一
    case folded(ToolCall)
    /// 命中本会话的「允许同类」规则，不进队列，调用方直接回 `allow`
    case autoAllowed(SimilarRule)
    /// R4：命中 settings.json 里的永久规则
    case autoAllowedPermanently(PermanentRule)
    /// 同一个 request id 重复提交，忽略
    case duplicate
}

/// 一次状态转移的结果，调用方据此回复对应的连接。
public struct ApprovalResolution: Sendable, Equatable {
    /// 转移后的行快照。`rowClosed == false`（只有部分折叠请求超时）时 status 仍是 pending。
    public var call: ToolCall
    /// 需要回复的 request id（折叠进同一行的每个请求各有一条连接）
    public var requestIDs: [String]
    public var decision: Decision
    public var rule: SimilarRule?
    public var rowClosed: Bool
}

/// 审批队列状态机：`pending -> allowed | denied | expired`。
/// 线程安全；时间只来自注入的 `Clock`，超时由调用方周期性调用 `expireDue()` 驱动。
public final class ApprovalStore: @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 90

    struct FoldKey: Hashable {
        let sessionID: String
        let tool: String
        let fingerprint: String
    }

    struct Member {
        let requestID: String
        let deadline: Date
    }

    struct Entry {
        var call: ToolCall
        var members: [Member]
        let seq: Int
        let key: FoldKey
    }

    private let lock = NSLock()
    private let clock: Clock
    private let classifier: RiskClassifier
    private var book: SimilarRuleBook
    private var permanentRules: [PermanentRule] = []
    private var _timeout: TimeInterval
    private var entries: [Entry] = []
    private var resolved: [ToolCall] = []
    private var nextSeq = 0
    private let historyLimit: Int

    public init(
        clock: Clock = SystemClock(),
        timeout: TimeInterval = ApprovalStore.defaultTimeout,
        classifier: RiskClassifier = RiskClassifier(),
        similarOptions: SimilarRuleOptions = SimilarRuleOptions(),
        historyLimit: Int = 200
    ) {
        self.clock = clock
        self._timeout = max(0, timeout)
        self.classifier = classifier
        self.book = SimilarRuleBook(options: similarOptions, classifier: classifier)
        self.historyLimit = max(0, historyLimit)
    }

    // MARK: Configuration

    /// 只影响之后提交的请求
    public var timeout: TimeInterval {
        get { lock.withLock { _timeout } }
        set { lock.withLock { _timeout = max(0, newValue) } }
    }

    public var similarOptions: SimilarRuleOptions {
        get { lock.withLock { book.options } }
        set { lock.withLock { book.options = newValue } }
    }

    // MARK: Queries

    /// 排序：风险降序，其次等待时间降序（先到的在前），最后按到达顺序，因此是稳定的。
    public var pending: [ToolCall] {
        lock.withLock {
            entries.sorted { a, b in
                if a.call.risk != b.call.risk { return a.call.risk > b.call.risk }
                if a.call.requestedAt != b.call.requestedAt { return a.call.requestedAt < b.call.requestedAt }
                return a.seq < b.seq
            }.map(\.call)
        }
    }

    /// 菜单栏角标：待处理的行数（折叠后），不是原始请求数
    public var pendingCount: Int { lock.withLock { entries.count } }

    /// 已结案的行（最近的在后），有上限
    public var history: [ToolCall] { lock.withLock { resolved } }

    /// 按行 id 或折叠进来的任一 request id 查找，待处理和已结案都找
    public func call(id: String) -> ToolCall? {
        lock.withLock {
            if let i = index(of: id) { return entries[i].call }
            return resolved.first { $0.id == id }
        }
    }

    /// 最早的一个超时时刻，供调度器决定何时再调用 `expireDue()`
    public var nextDeadline: Date? {
        lock.withLock { entries.flatMap(\.members).map(\.deadline).min() }
    }

    public func canOfferAllowSimilar(id: String) -> Bool {
        lock.withLock {
            guard let i = index(of: id) else { return false }
            return makeRule(for: entries[i]) != nil
        }
    }

    public func similarRules(session sessionID: String) -> [SimilarRule] {
        lock.withLock { book.rules.filter { $0.sessionID == sessionID } }
    }

    /// Replaces the rules loaded from `permissions.allow`. Sessions do not own these rules.
    public func replacePermanentRules(_ rules: [PermanentRule]) {
        lock.withLock { permanentRules = rules }
    }

    public var currentPermanentRules: [PermanentRule] {
        lock.withLock { permanentRules }
    }

    /// R4: the exact line that would be appended, or nil when this request cannot be made permanent.
    public func permanentRuleSnippet(id: String) -> String? {
        lock.withLock {
            guard let i = index(of: id), let rule = PermanentRule.make(for: entries[i].call),
                  !permanentRules.contains(rule) else { return nil }
            return rule.text
        }
    }

    // MARK: Submit

    @discardableResult
    public func submit(
        requestID: String, sessionID: String, agent: AgentKind, tool: String,
        input: [String: JSONValue], cwd: String
    ) -> SubmitOutcome {
        let risk = classifier.classify(tool: tool, input: input)
        let key = FoldKey(
            sessionID: sessionID, tool: tool.lowercased(),
            fingerprint: CommandNormalizer.fingerprint(tool: tool, input: input))
        return lock.withLock {
            if index(of: requestID) != nil { return .duplicate }
            let now = clock.now()
            if let rule = permanentRules.first(where: { $0.matches(tool: tool, input: input) }) {
                return .autoAllowedPermanently(rule)
            }
            if let rule = book.match(sessionID: sessionID, tool: tool, input: input, risk: risk) {
                return .autoAllowed(rule)
            }
            let member = Member(requestID: requestID, deadline: now.addingTimeInterval(_timeout))
            if let i = entries.firstIndex(where: { $0.key == key }) {
                entries[i].members.append(member)
                entries[i].call.repeatCount = entries[i].members.count
                return .folded(entries[i].call)
            }
            let call = ToolCall(
                id: requestID, sessionID: sessionID, agent: agent, tool: tool, input: input,
                cwd: cwd, risk: risk, requestedAt: now)
            entries.append(Entry(call: call, members: [member], seq: nextSeq, key: key))
            nextSeq += 1
            return .queued(call)
        }
    }

    // MARK: Decisions

    @discardableResult
    public func allow(id: String) throws -> ApprovalResolution {
        try lock.withLock { try close(id: id, status: .allowed, decision: .allow, rule: nil) }
    }

    /// R3：原因去掉首尾空白后不能为空；不合格时条目保持 pending
    @discardableResult
    public func deny(id: String, reason: String) throws -> ApprovalResolution {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ApprovalError.emptyReason }
        return try lock.withLock { try close(id: id, status: .denied, decision: .deny(reason: trimmed), rule: nil) }
    }

    @discardableResult
    public func allowSimilar(id: String) throws -> ApprovalResolution {
        try lock.withLock {
            guard let i = index(of: id) else { throw lookupError(id) }
            guard let rule = makeRule(for: entries[i]) else { throw ApprovalError.similarNotEligible }
            book.add(rule)
            return try close(id: id, status: .allowed, decision: .allowSimilar, rule: rule)
        }
    }

    // MARK: Lifecycle

    /// R1：把到期的请求结案为 `noDecision`。永远不会变成允许。
    @discardableResult
    public func expireDue() -> [ApprovalResolution] {
        lock.withLock {
            let now = clock.now()
            var out: [ApprovalResolution] = []
            var kept: [Entry] = []
            for var entry in entries {
                let due = entry.members.filter { $0.deadline <= now }
                guard !due.isEmpty else { kept.append(entry); continue }
                entry.members.removeAll { $0.deadline <= now }
                if entry.members.isEmpty {
                    entry.call.status = .expired
                    remember(entry.call)
                    out.append(ApprovalResolution(
                        call: entry.call, requestIDs: due.map(\.requestID),
                        decision: .noDecision, rule: nil, rowClosed: true))
                } else {
                    entry.call.repeatCount = entry.members.count
                    out.append(ApprovalResolution(
                        call: entry.call, requestIDs: due.map(\.requestID),
                        decision: .noDecision, rule: nil, rowClosed: false))
                    kept.append(entry)
                }
            }
            entries = kept
            return out
        }
    }

    /// 连接断开：对应请求立即作废。该行没有别的折叠请求时整行移除。
    /// 不记入历史，也不需要回复（连接已经没了）。返回是否找到。
    @discardableResult
    public func connectionDropped(requestID: String) -> Bool {
        lock.withLock {
            guard let i = entries.firstIndex(where: { $0.members.contains { $0.requestID == requestID } })
            else { return false }
            entries[i].members.removeAll { $0.requestID == requestID }
            if entries[i].members.isEmpty {
                entries.remove(at: i)
            } else {
                entries[i].call.repeatCount = entries[i].members.count
            }
            return true
        }
    }

    /// session 结束：清除它的「允许同类」规则，待处理请求按无决策结案
    @discardableResult
    public func endSession(_ sessionID: String) -> [ApprovalResolution] {
        lock.withLock {
            book.removeAll(session: sessionID)
            var out: [ApprovalResolution] = []
            entries.removeAll { entry in
                guard entry.call.sessionID == sessionID else { return false }
                var call = entry.call
                call.status = .expired
                remember(call)
                out.append(ApprovalResolution(
                    call: call, requestIDs: entry.members.map(\.requestID),
                    decision: .noDecision, rule: nil, rowClosed: true))
                return true
            }
            return out
        }
    }

    // MARK: Internals (call with lock held)

    private func index(of id: String) -> Int? {
        entries.firstIndex { $0.call.id == id || $0.members.contains { $0.requestID == id } }
    }

    private func lookupError(_ id: String) -> ApprovalError {
        resolved.contains { $0.id == id } ? .notPending : .notFound
    }

    private func makeRule(for entry: Entry) -> SimilarRule? {
        book.makeRule(
            sessionID: entry.call.sessionID, tool: entry.call.tool,
            input: entry.call.input, risk: entry.call.risk)
    }

    private func close(id: String, status: ToolCallStatus, decision: Decision, rule: SimilarRule?) throws -> ApprovalResolution {
        guard let i = index(of: id) else { throw lookupError(id) }
        var entry = entries.remove(at: i)
        entry.call.status = status
        remember(entry.call)
        return ApprovalResolution(
            call: entry.call, requestIDs: entry.members.map(\.requestID),
            decision: decision, rule: rule, rowClosed: true)
    }

    private func remember(_ call: ToolCall) {
        guard historyLimit > 0 else { return }
        resolved.append(call)
        if resolved.count > historyLimit { resolved.removeFirst(resolved.count - historyLimit) }
    }
}
