import MusterProtocol
import Foundation

/// 把 socket 请求接到 `ApprovalStore` 和 `SessionStore` 上。
///
/// 只做「协议 <-> 领域模型」的翻译和连接生命周期，不含 UI。
/// 关键约束：
/// - 折叠后的一行对应多条连接：一次决策必须回复该行所有 `requestIDs`。
/// - 没有任何东西会自动调用 `expireDue()`，所以这里按 `nextDeadline` 安排定时器。
/// - 等待期间连接断开 -> `connectionDropped` 立即撤销，面板条目随之消失。
/// - 任何异常都返回 `noDecision`，绝不变成允许（R2）。
public final class AgentDaemon: RequestHandling, @unchecked Sendable {
    public let approvals: ApprovalStore
    public let sessions: SessionStore
    private let log: DiagnosticSink

    /// 待审批队列或会话状态变化时调用（任意线程）。UI 据此刷新，不必轮询。
    public var onChange: (@Sendable () -> Void)?

    private let waiters = WaiterTable()
    private let timerQueue = DispatchQueue(label: "muster.daemon.expiry")
    private let timerLock = NSLock()
    private var timer: DispatchSourceTimer?

    public init(
        approvals: ApprovalStore = ApprovalStore(),
        sessions: SessionStore = SessionStore(),
        log: @escaping DiagnosticSink = Diagnostics.default
    ) {
        self.approvals = approvals
        self.sessions = sessions
        self.log = log
    }

    deinit { stop() }

    // MARK: - Lifecycle

    public func start() {
        scheduleExpiry()
    }

    /// 停止时让所有挂起的请求按无决策返回，hook 不必白等到超时。
    public func stop() {
        timerLock.lock()
        let t = timer
        timer = nil
        timerLock.unlock()
        t?.cancel()

        for id in waiters.drain() {
            log("daemon stopped with pending request \(id)")
        }
    }

    // MARK: - RequestHandling

    public func handle(_ request: WireRequest) async -> WireResponse {
        guard request.v == Wire.version, let agent = AgentKind(rawValue: request.agent) else {
            return noDecision(request)
        }

        let summary = ToolSummary.line(tool: request.tool, input: request.input, cwd: request.cwd)
        let outcome = approvals.submit(
            requestID: request.id, sessionID: request.session, agent: agent,
            tool: request.tool, input: request.input, cwd: request.cwd)

        switch outcome {
        case .duplicate:
            return noDecision(request)

        case .autoAllowed:
            apply(
                session: request.session, agent: agent, cwd: request.cwd,
                kind: .toolCall(summary: summary), request: request)
            return WireResponse(
                id: request.id, decision: .allow,
                reason: "Allowed by this session's similar-operation rule", ttlMs: ttlMs)

        case .autoAllowedPermanently(let rule):
            apply(
                session: request.session, agent: agent, cwd: request.cwd,
                kind: .toolCall(summary: summary), request: request)
            return WireResponse(
                id: request.id, decision: .allow,
                reason: "Allowed by the permanent rule \(rule.text)", ttlMs: ttlMs)

        case .queued(let call), .folded(let call):
            apply(
                session: request.session, agent: agent, cwd: request.cwd, kind: .waiting,
                request: request)
            apply(
                session: request.session, agent: agent, cwd: request.cwd,
                kind: .toolCall(summary: summary), request: request)
            // 提交时可能已经到期（timeout 很小），先结算一次再决定是否等待
            sweepExpired()
            onChange?()
            guard let response = await waitForDecision(requestID: request.id) else {
                return noDecision(request)
            }
            _ = call
            return response
        }
    }

    public func requestCancelled(_ request: WireRequest) async {
        approvals.connectionDropped(requestID: request.id)
        waiters.remove(request.id)?.resume(returning: nil)
        onChange?()
    }

    // MARK: - UI -> 连接

    /// UI 做出决策后调用：回复该行所有连接，并更新会话状态。
    public func resolve(_ resolution: ApprovalResolution) {
        let text = reasonText(resolution.decision)
        for id in resolution.requestIDs {
            waiters.remove(id)?.resume(returning: WireResponse(
                id: id, decision: wireDecision(resolution.decision),
                reason: text, ttlMs: ttlMs))
        }
        defer { onChange?() }
        guard resolution.rowClosed else { return }
        let call = resolution.call
        let kind: SessionHookEvent.Kind = call.status == .denied ? .idle : .idle
        apply(session: call.sessionID, agent: call.agent, cwd: call.cwd, kind: kind)
    }

    /// 周期性结算超时；UI 也可以直接调这个方法。
    public func sweepExpired() {
        for resolution in approvals.expireDue() {
            resolve(resolution)
        }
        scheduleExpiry()
    }

    // MARK: - Internals

    private func waitForDecision(requestID: String) async -> WireResponse? {
        await withCheckedContinuation { (cont: CheckedContinuation<WireResponse?, Never>) in
            waiters.add(requestID, cont)
        }
    }

    private func apply(
        session: String, agent: AgentKind, cwd: String, kind: SessionHookEvent.Kind,
        request: WireRequest? = nil
    ) {
        sessions.apply(SessionHookEvent(
            sessionID: session, agent: agent, cwd: cwd.isEmpty ? nil : cwd,
            pid: request?.pid,
            pidStartTime: request?.pidStartedAt.map { Date(timeIntervalSince1970: $0) },
            kind: kind, at: Date()))
    }

    private func scheduleExpiry() {
        guard let next = approvals.nextDeadline else { return }
        timerLock.lock(); defer { timerLock.unlock() }
        timer?.cancel()
        let delay = max(0.05, next.timeIntervalSinceNow)
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + delay, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.sweepExpired() }
        t.resume()
        timer = t
    }

    private var ttlMs: Int { Int((approvals.timeout * 1000).rounded()) }

    private func noDecision(_ request: WireRequest) -> WireResponse {
        WireResponse(id: request.id, decision: .noDecision, ttlMs: ttlMs)
    }

    private func wireDecision(_ d: Decision) -> WireDecision {
        switch d {
        case .allow: return .allow
        case .deny: return .deny
        case .allowSimilar: return .allowSimilar
        case .noDecision: return .noDecision
        }
    }

    private func reasonText(_ d: Decision) -> String? {
        if case .deny(let reason) = d { return reason }
        return nil
    }
}

/// `CheckedContinuation` 的并发安全表：每个 request id 只挂起一次、取出一次。
final class WaiterTable: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: CheckedContinuation<WireResponse?, Never>] = [:]

    func add(_ id: String, _ cont: CheckedContinuation<WireResponse?, Never>) {
        lock.lock()
        let previous = map.updateValue(cont, forKey: id)
        lock.unlock()
        // 同一 id 重复提交：旧的那个永远不会再被回复，按无决策结束
        previous?.resume(returning: nil)
    }

    func remove(_ id: String) -> CheckedContinuation<WireResponse?, Never>? {
        lock.lock(); defer { lock.unlock() }
        return map.removeValue(forKey: id)
    }

    /// 取出全部并返回它们的 id；每个 continuation 以无决策结束。
    func drain() -> [String] {
        lock.lock()
        let snapshot = map
        map.removeAll()
        lock.unlock()
        for (_, cont) in snapshot { cont.resume(returning: nil) }
        return Array(snapshot.keys)
    }
}
