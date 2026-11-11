import MusterProtocol
import Darwin
import Foundation

extension SocketServer {
    /// 在连接读线程上运行：校验对端、读一行、分发给 handler，然后一直监视对端是否断开。
    func serve(_ conn: Connection) {
        defer { conn.closeFD() }

        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(conn.fd, &uid, &gid) == 0, uid == allowedUID else { return }

        var reader = LineReader(fd: conn.fd)
        let line: Data
        switch reader.readLine(timeout: requestReadTimeout) {
        case .line(let d): line = d
        case .tooLong, .eof, .timeout, .error: return // 超长/半截/空连接：直接断开
        }

        guard let request = parse(line: line, conn: conn) else { return }

        let handler = self.handler
        let task = Task {
            var response = await handler.handle(request)
            response.id = request.id
            if Task.isCancelled { return }
            let data = (try? WireCodec.encodeLine(response))
                ?? (try? WireCodec.encodeLine(WireResponse(id: request.id, decision: .noDecision)))
                ?? Data()
            conn.tryRespond(data)
        }

        // 等待对端关闭，或者响应已写回（tryRespond 会 shutdown，唤醒这里）。
        var sink = [UInt8](repeating: 0, count: 4096)
        while conn.isWaiting {
            var p = pollfd(fd: conn.fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, 250)
            if r < 0 {
                if errno == EINTR { continue }
                break
            }
            if r == 0 { continue }
            let n = read(conn.fd, &sink, sink.count)
            if n > 0 { continue } // 请求之后的多余字节忽略
            if n < 0, errno == EINTR || errno == EAGAIN { continue }
            break
        }

        if conn.tryCancel() {
            task.cancel()
            Task { await handler.requestCancelled(request) }
        }
    }

    /// 解析失败或版本未知时直接回 no_decision 并返回 nil。
    private func parse(line: Data, conn: Connection) -> WireRequest? {
        func reply(id: String, reason: String) {
            var r = WireResponse(id: id, decision: .noDecision, reason: reason)
            r.ttlMs = nil
            if let data = try? WireCodec.encodeLine(r) { conn.tryRespond(data) }
        }

        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
              case .object(let obj) = value else {
            reply(id: "", reason: "invalid json")
            return nil
        }
        let id = obj["id"]?.stringValue ?? ""
        guard case .int(let v)? = obj["v"], v == Wire.version else {
            reply(id: id, reason: "unsupported version")
            return nil
        }
        guard obj["type"]?.stringValue == "request",
              let request = try? WireCodec.decode(WireRequest.self, line: line) else {
            reply(id: id, reason: "invalid request")
            return nil
        }
        return request
    }
}
