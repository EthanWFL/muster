import MusterProtocol
import Foundation
import Testing

@testable import MusterCore

/// AgentDaemon 的接线测试：协议 <-> ApprovalStore/SessionStore 的翻译与连接生命周期。
@Suite(.serialized) struct AgentDaemonTests {
    struct Harness {
        let clock = ApprovalTestClock()
        let approvals: ApprovalStore
        let daemon: AgentDaemon
        let socket: TempSocket
        let server: SocketServer

        init() {
            approvals = ApprovalStore(clock: clock, timeout: 90)
            daemon = AgentDaemon(approvals: approvals, sessions: SessionStore(clock: clock))
            socket = TempSocket()
            server = SocketServer(path: socket.path, handler: daemon)
        }

        func request(id: String, command: String, session: String = "s1") -> WireRequest {
            WireRequest(id: id, session: session, agent: "claude", tool: "Bash",
                        input: ["command": .string(command)], cwd: "/tmp/proj", ts: 0)
        }

        /// 一个测试里可能开多个客户端，server 只启动一次
        func startServerOnce() throws {
            do { try server.start() } catch SocketServerError.alreadyStarted {} 
        }
    }

    /// 用一个真实客户端连 socket 发请求，同时拿到结果。
    static func start(_ h: Harness, _ req: WireRequest) throws -> (RawClient, Task<WireResponse?, Never>) {
        try h.startServerOnce()
        let client = try #require(RawClient(path: h.socket.path))
        try client.send(WireCodec.encodeLine(req))
        let task = Task { () -> WireResponse? in
            guard let line = client.readLine(timeout: 5) else { return nil }
            return try? WireCodec.decode(WireResponse.self, line: line)
        }
        return (client, task)
    }

    @Test func queuedRequestBecomesAllowWhenApproved() async throws {
        let h = Harness()
        h.daemon.start()
        defer { h.server.stop(); h.daemon.stop(); h.socket.cleanup(); }

        let (client, task) = try Self.start(h, h.request(id: "c1", command: "ls -la"))
        defer { client.closeNow() }

        // 等它进入队列
        try await waitUntil { h.approvals.pendingCount == 1 }
        let row = try #require(h.approvals.pending.first)
        #expect(row.risk == .low)
        h.daemon.resolve(try h.approvals.allow(id: row.id))

        let response = try #require(await task.value)
        #expect(response.decision == .allow)
        #expect(response.id == "c1")
        #expect(h.approvals.pendingCount == 0)
    }

    @Test func denyCarriesTheReasonBack() async throws {
        let h = Harness()
        h.daemon.start()
        defer { h.server.stop(); h.daemon.stop(); h.socket.cleanup() }

        let (client, task) = try Self.start(h, h.request(id: "c2", command: "git push origin main"))
        defer { client.closeNow() }
        try await waitUntil { h.approvals.pendingCount == 1 }
        let row = try #require(h.approvals.pending.first)
        h.daemon.resolve(try h.approvals.deny(id: row.id, reason: "not now"))

        let response = try #require(await task.value)
        #expect(response.decision == .deny)
        #expect(response.reason == "not now")
    }

    /// R1：超时后回 no_decision，绝不变成 allow，面板条目也消失。
    @Test func timeoutYieldsNoDecision() async throws {
        let h = Harness()
        h.daemon.start()
        defer { h.server.stop(); h.daemon.stop(); h.socket.cleanup() }

        let (client, task) = try Self.start(h, h.request(id: "c3", command: "touch a.txt"))
        defer { client.closeNow() }
        try await waitUntil { h.approvals.pendingCount == 1 }

        h.clock.advance(91)
        h.daemon.sweepExpired()
        // 定时器也会在真实时间 0.05s 后触发，所以这里不要求立刻得到结果
        let response = try #require(await task.value)
        #expect(response.decision == .noDecision)
        #expect(h.approvals.pendingCount == 0)
    }

    /// R2/连接断开：hook 被杀 -> 条目立即消失。
    @Test func droppedConnectionRemovesTheRow() async throws {
        let h = Harness()
        h.daemon.start()
        defer { h.server.stop(); h.daemon.stop(); h.socket.cleanup() }

        let client = try startAndDrop(h, h.request(id: "c4", command: "touch b.txt"))
        try await waitUntil { h.approvals.pendingCount == 0 }
        // 连接已断开，不会有任何决策写回
        #expect(client.readLine(timeout: 0.3) == nil)
    }

    /// R5：同一命令折叠成一行，一次决策回复所有连接。
    @Test func foldedRequestsShareOneRowAndOneDecision() async throws {
        let h = Harness()
        h.daemon.start()
        defer { h.server.stop(); h.daemon.stop(); h.socket.cleanup() }
        try h.server.start()

        var clients: [RawClient] = []
        for id in ["f1", "f2", "f3"] {
            let c = try #require(RawClient(path: h.socket.path))
            try c.send(WireCodec.encodeLine(h.request(id: id, command: "npm test")))
            clients.append(c)
        }
        defer { clients.forEach { $0.closeNow() } }

        try await waitUntil { h.approvals.pendingCount == 1 }
        let row = try #require(h.approvals.pending.first)
        #expect(row.repeatCount == 3)

        h.daemon.resolve(try h.approvals.allow(id: row.id))
        for c in clients {
            let line = try #require(try c.readLine(timeout: 5))
            let response = try #require(try? WireCodec.decode(WireResponse.self, line: line))
            #expect(response.decision == .allow)
        }
        #expect(h.approvals.pendingCount == 0)
    }

    /// 允许同类：第二条不进队列，直接 allow。
    @Test func similarRuleAutoAllowsWithoutQueueing() async throws {
        let h = Harness()
        h.daemon.start()
        defer { h.server.stop(); h.daemon.stop(); h.socket.cleanup() }

        let (c1, t1) = try Self.start(h, h.request(id: "s1a", command: "git status --short"))
        try await waitUntil { h.approvals.pendingCount == 1 }
        let row = try #require(h.approvals.pending.first)
        h.daemon.resolve(try h.approvals.allowSimilar(id: row.id))
        let r1 = try #require(await t1.value)
        #expect(r1.decision == .allowSimilar)
        c1.closeNow()

        let (c2, t2) = try Self.start(h, h.request(id: "s1b", command: "git status --long"))
        defer { c2.closeNow() }
        let r2 = try #require(await t2.value)
        #expect(r2.decision == .allow)
        #expect(h.approvals.pendingCount == 0)
    }

    /// 未知协议版本一律 no_decision，不崩溃、不排队。
    @Test func unknownVersionIsNoDecision() async throws {
        let h = Harness()
        h.daemon.start()
        defer { h.server.stop(); h.daemon.stop(); h.socket.cleanup() }

        var req = h.request(id: "v9", command: "ls")
        req.v = 99
        let (client, task) = try Self.start(h, req)
        defer { client.closeNow() }
        let response = try #require(await task.value)
        #expect(response.decision == .noDecision)
        #expect(h.approvals.pendingCount == 0)
    }

    private func startAndDrop(_ h: Harness, _ req: WireRequest) throws -> RawClient {
        try h.server.start()
        let client = try #require(RawClient(path: h.socket.path))
        try client.send(WireCodec.encodeLine(req))
        client.closeNow()
        return client
    }
}

/// 轮询等待某个条件；测试里只在极短窗口内使用。
func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
