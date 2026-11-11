import MusterProtocol
import Darwin
import Foundation

@testable import MusterCore

/// /tmp 下的短路径（sun_path 只有 104 字节，NSTemporaryDirectory 太长）。
struct TempSocket {
    let dir: String
    let path: String

    init() {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        dir = "/tmp/ap-\(token)"
        path = dir + "/s.sock"
    }

    func cleanup() {
        unlink(path)
        rmdir(dir)
    }
}

/// 最小的阻塞式 NDJSON 客户端，只在测试里用。
final class RawClient {
    let fd: Int32

    init?(path: String) {
        guard var addr = SocketPath.makeAddress(path: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(fd); return nil }
        self.fd = fd
    }

    deinit { close(fd) }

    @discardableResult
    func send(_ data: Data) -> Bool { UnixSocket.writeAll(fd: fd, data: data) }

    func sendLine(_ text: String) { send(Data((text + "\n").utf8)) }

    func sendRequest(_ request: WireRequest) {
        send((try? WireCodec.encodeLine(request)) ?? Data())
    }

    /// 读到换行、EOF 或超时。EOF/超时返回 nil。
    func readLine(timeout: TimeInterval = 5) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) { return Data(buffer[buffer.startIndex..<idx]) }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, Int32(remaining * 1000) + 1)
            if r < 0 { if errno == EINTR { continue }; return nil }
            if r == 0 { continue }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { buffer.append(chunk, count: n) } else if n == 0 { return nil } else if errno != EINTR && errno != EAGAIN { return nil }
        }
    }

    func readResponse(timeout: TimeInterval = 5) -> WireResponse? {
        guard let line = readLine(timeout: timeout) else { return nil }
        return try? JSONDecoder().decode(WireResponse.self, from: line)
    }

    /// 等对端关闭连接（read 返回 0）。
    func waitForClose(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, 100)
            if r <= 0 { continue }
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { return true }
            if n < 0 && errno != EINTR && errno != EAGAIN { return true }
        }
        return false
    }

    func closeNow() { Darwin.shutdown(fd, SHUT_RDWR) }
}

func makeRequest(_ id: String, tool: String = "Bash") -> WireRequest {
    WireRequest(
        id: id, session: "s1", agent: "claude", tool: tool,
        input: ["command": .string("echo \(id)")], cwd: "/tmp", ts: 1_730_000_000
    )
}

/// 线程安全的事件记录，带信号量以便同步等待。
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var handled: [String] = []
    private var cancelled: [String] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private let cancelSignal = DispatchSemaphore(value: 0)

    func began(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        handled.append(id)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    func ended() {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
    }

    func didCancel(_ id: String) {
        lock.lock()
        cancelled.append(id)
        lock.unlock()
        cancelSignal.signal()
    }

    func waitForCancel(timeout: TimeInterval = 5) -> Bool {
        cancelSignal.wait(timeout: .now() + timeout) == .success
    }

    var handledIDs: [String] { lock.lock(); defer { lock.unlock() }; return handled }
    var cancelledIDs: [String] { lock.lock(); defer { lock.unlock() }; return cancelled }
}
