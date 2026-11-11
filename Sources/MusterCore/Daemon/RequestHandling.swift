import MusterProtocol

/// 面板侧（ApprovalStore）实现的接口，SocketServer 只依赖它。
public protocol RequestHandling: Sendable {
    /// 返回该请求的决策。服务端会把返回值的 `id` 强制改成请求的 `id`。
    /// 连接断开时，承载本调用的 Task 会被取消。
    func handle(_ request: WireRequest) async -> WireResponse

    /// 连接在决策写回之前断开（hook 被杀、Claude 中断、服务停止）。
    /// 对同一个请求最多调用一次；已经写回决策的请求不会调用。
    func requestCancelled(_ request: WireRequest) async
}

/// 闭包版本，便于测试和临时装配。
public struct ClosureRequestHandler: RequestHandling {
    private let onRequest: @Sendable (WireRequest) async -> WireResponse
    private let onCancel: @Sendable (WireRequest) async -> Void

    public init(
        onRequest: @escaping @Sendable (WireRequest) async -> WireResponse,
        onCancel: @escaping @Sendable (WireRequest) async -> Void = { _ in }
    ) {
        self.onRequest = onRequest
        self.onCancel = onCancel
    }

    public func handle(_ request: WireRequest) async -> WireResponse { await onRequest(request) }
    public func requestCancelled(_ request: WireRequest) async { await onCancel(request) }
}
