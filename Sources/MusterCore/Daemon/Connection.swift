import MusterProtocol
import Darwin
import Foundation

/// 一条已 accept 的连接。fd 只由读线程关闭；写入和关闭都在 `lock` 内，避免 fd 复用后误写。
final class Connection: @unchecked Sendable {
    enum State { case waiting, responded, cancelled }

    let fd: Int32
    private let lock = NSLock()
    private var state: State = .waiting
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    var isWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return state == .waiting
    }

    /// 写回响应并半关闭以唤醒读线程。只有 `waiting` 状态能成功，决策和取消二者先到先得。
    @discardableResult
    func tryRespond(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .waiting, !closed else { return false }
        state = .responded
        UnixSocket.writeAll(fd: fd, data: data)
        shutdown(fd, SHUT_RDWR)
        return true
    }

    /// 返回 true 表示本次调用把请求标记为已取消（调用方负责触发取消回调）。
    func tryCancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .waiting else { return false }
        state = .cancelled
        return true
    }

    func shutdownForStop() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        shutdown(fd, SHUT_RDWR)
    }

    func closeFD() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        close(fd)
    }
}

enum LineResult {
    case line(Data)
    case tooLong
    case eof
    case timeout
    case error
}

/// 带上限和截止时间的按行读取。
struct LineReader {
    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    mutating func readLine(timeout: TimeInterval) -> LineResult {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<idx])
                buffer.removeSubrange(buffer.startIndex...idx)
                return line.count > Wire.maxLineBytes ? .tooLong : .line(line)
            }
            if buffer.count > Wire.maxLineBytes { return .tooLong }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timeout }
            let remainingMs = Int32(min(UInt64(Int32.max), (deadline - now) / 1_000_000 + 1))
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, remainingMs)
            if r < 0 {
                if errno == EINTR { continue }
                return .error
            }
            if r == 0 { continue }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(chunk, count: n)
            } else if n == 0 {
                return .eof
            } else if errno == EINTR || errno == EAGAIN {
                continue
            } else {
                return .error
            }
        }
    }
}
