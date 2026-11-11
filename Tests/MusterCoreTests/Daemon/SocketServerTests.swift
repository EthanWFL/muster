import MusterProtocol
import Darwin
import Foundation
import Testing

@testable import MusterCore

func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

@Suite(.serialized) struct SocketServerTests {
    private func allowHandler(_ log: EventLog, delayMs: UInt64 = 0) -> ClosureRequestHandler {
        ClosureRequestHandler(
            onRequest: { req in
                log.began(req.id)
                defer { log.ended() }
                if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
                return WireResponse(id: req.id, decision: .allow, ttlMs: 90_000)
            },
            onCancel: { req in log.didCancel(req.id) }
        )
    }

    @Test func fiftyConcurrentRequests() throws {
        let tmp = TempSocket()
        defer { tmp.cleanup() }
        let log = EventLog()
        let server = SocketServer(path: tmp.path, handler: allowHandler(log, delayMs: 100))
        try server.start()
        defer { server.stop() }

        let n = 50
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [String: WireDecision] = [:]
        for i in 0..<n {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                guard let c = RawClient(path: tmp.path) else { return }
                c.sendRequest(makeRequest("r\(i)"))
                if let resp = c.readResponse(timeout: 10) {
                    lock.lock(); results["r\(i)"] = resp.decision; lock.unlock()
                }
            }
        }
        #expect(group.wait(timeout: .now() + 20) == .success)
        #expect(results.count == n)
        #expect(results.values.allSatisfy { $0 == .allow })
        #expect(Set(log.handledIDs).count == n)
        #expect(log.cancelledIDs.isEmpty)
    }

    @Test func midRequestDisconnectCancels() throws {
        let tmp = TempSocket()
        defer { tmp.cleanup() }
        let log = EventLog()
        let handler = ClosureRequestHandler(
            onRequest: { req in
                log.began(req.id)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return WireResponse(id: req.id, decision: .allow)
            },
            onCancel: { req in log.didCancel(req.id) }
        )
        let server = SocketServer(path: tmp.path, handler: handler)
        try server.start()
        defer { server.stop() }

        let client = try #require(RawClient(path: tmp.path))
        client.sendRequest(makeRequest("gone"))
        #expect(waitUntil { log.handledIDs == ["gone"] })
        client.closeNow()
        #expect(log.waitForCancel())
        #expect(log.cancelledIDs == ["gone"])
    }

    @Test func respondedRequestIsNotReportedCancelled() throws {
        let tmp = TempSocket()
        defer { tmp.cleanup() }
        let log = EventLog()
        let server = SocketServer(path: tmp.path, handler: allowHandler(log))
        try server.start()
        defer { server.stop() }

        let client = try #require(RawClient(path: tmp.path))
        client.sendRequest(makeRequest("ok"))
        let resp = try #require(client.readResponse())
        #expect(resp.id == "ok")
        #expect(resp.decision == .allow)
        #expect(client.waitForClose())
        #expect(!log.waitForCancel(timeout: 0.5))
        #expect(log.cancelledIDs.isEmpty)
    }

    @Test func oversizeLineDisconnects() throws {
        let tmp = TempSocket()
        defer { tmp.cleanup() }
        let log = EventLog()
        let server = SocketServer(path: tmp.path, handler: allowHandler(log))
        try server.start()
        defer { server.stop() }

        let client = try #require(RawClient(path: tmp.path))
        // 超过上限且没有换行，服务端必须在读满上限后断开
        client.send(Data(repeating: 0x61, count: Wire.maxLineBytes + 4096))
        #expect(client.waitForClose())
        #expect(log.handledIDs.isEmpty)

        // 服务端仍然可用
        let again = try #require(RawClient(path: tmp.path))
        again.sendRequest(makeRequest("after"))
        #expect(again.readResponse()?.decision == .allow)
    }

    @Test func invalidJSONGetsNoDecision() throws {
        let tmp = TempSocket()
        defer { tmp.cleanup() }
        let log = EventLog()
        let server = SocketServer(path: tmp.path, handler: allowHandler(log))
        try server.start()
        defer { server.stop() }

        let client = try #require(RawClient(path: tmp.path))
        client.sendLine("{not json")
        let resp = try #require(client.readResponse())
        #expect(resp.decision == .noDecision)
        #expect(log.handledIDs.isEmpty)
    }

    @Test func unknownVersionGetsNoDecision() throws {
        let tmp = TempSocket()
        defer { tmp.cleanup() }
        let log = EventLog()
        let server = SocketServer(path: tmp.path, handler: allowHandler(log))
        try server.start()
        defer { server.stop() }

        let client = try #require(RawClient(path: tmp.path))
        client.sendLine(#"{"v":99,"type":"request","id":"x1","session":"s","agent":"claude","tool":"Bash","input":{},"cwd":"/","ts":1}"#)
        let resp = try #require(client.readResponse())
        #expect(resp.decision == .noDecision)
        #expect(resp.id == "x1")
        #expect(log.handledIDs.isEmpty)
    }

    @Test func staleSocketFileIsRemoved() throws {
        let tmp = TempSocket()
        defer { tmp.cleanup() }
        try FileManager.default.createDirectory(
            atPath: tmp.dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // 制造残留：bind 之后不 listen 直接关闭，文件留在磁盘上
        var addr = try #require(SocketPath.makeAddress(path: tmp.path))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(UnixSocket.bindSocket(fd: fd, address: addr) == 0)
        close(fd)
        var st = stat()
        #expect(lstat(tmp.path, &st) == 0)
        _ = addr.sun_family

        let log = EventLog()
        let server = SocketServer(path: tmp.path, handler: allowHandler(log))
        try server.start()
        defer { server.stop() }

        let client = try #require(RawClient(path: tmp.path))
        client.sendRequest(makeRequest("fresh"))
        #expect(client.readResponse()?.decision == .allow)
    }

    @Test func liveSocketIsNotStolen() throws {
        let tmp = TempSocket()
        defer { tmp.cleanup() }
        let log = EventLog()
        let first = SocketServer(path: tmp.path, handler: allowHandler(log))
        try first.start()
        defer { first.stop() }

        let second = SocketServer(path: tmp.path, handler: allowHandler(log))
        #expect(throws: SocketServerError.addressInUse(tmp.path)) { try second.start() }

        // 第一个服务端不受影响
        let client = try #require(RawClient(path: tmp.path))
        client.sendRequest(makeRequest("still"))
        #expect(client.readResponse()?.decision == .allow)
    }

    @Test func regularFileIsNotDeleted() throws {
        let tmp = TempSocket()
        defer { tmp.cleanup() }
        try FileManager.default.createDirectory(
            atPath: tmp.dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(FileManager.default.createFile(atPath: tmp.path, contents: Data("keep".utf8)))

        let server = SocketServer(path: tmp.path, handler: allowHandler(EventLog()))
        #expect(throws: SocketServerError.notASocket(tmp.path)) { try server.start() }
        #expect(FileManager.default.fileExists(atPath: tmp.path))
    }

    @Test func pathTooLongIsRejected() {
        let long = "/tmp/" + String(repeating: "a", count: 120) + "/s.sock"
        #expect(long.utf8.count >= 104)
        let server = SocketServer(path: long, handler: allowHandler(EventLog()))
        #expect(throws: SocketServerError.pathTooLong(bytes: long.utf8.count)) { try server.start() }

        // 边界：103 字节可以，104 字节不行
        let base = "/tmp/ap-edge/"
        let ok = base + String(repeating: "b", count: 103 - base.utf8.count)
        #expect(ok.utf8.count == 103)
        #expect(SocketPath.makeAddress(path: ok) != nil)
        #expect(SocketPath.makeAddress(path: ok + "b") == nil)
    }

    @Test func permissionsAreRestrictive() throws {
        let tmp = TempSocket()
        defer { tmp.cleanup() }
        let server = SocketServer(path: tmp.path, handler: allowHandler(EventLog()))
        try server.start()
        defer { server.stop() }

        var st = stat()
        #expect(stat(tmp.dir, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
        #expect(stat(tmp.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
    }

    @Test func stopRemovesSocketAndCancelsPending() throws {
        let tmp = TempSocket()
        defer { tmp.cleanup() }
        let log = EventLog()
        let handler = ClosureRequestHandler(
            onRequest: { req in
                log.began(req.id)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return WireResponse(id: req.id, decision: .allow)
            },
            onCancel: { req in log.didCancel(req.id) }
        )
        let server = SocketServer(path: tmp.path, handler: handler)
        try server.start()

        let client = try #require(RawClient(path: tmp.path))
        client.sendRequest(makeRequest("pending"))
        #expect(waitUntil { log.handledIDs == ["pending"] })
        server.stop()
        #expect(log.waitForCancel())
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
        #expect(client.waitForClose())
    }
}
