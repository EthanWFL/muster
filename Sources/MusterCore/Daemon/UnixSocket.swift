import Darwin
import Foundation

/// 极薄的 POSIX 封装，仅供 Daemon 目录内使用。
enum UnixSocket {
    /// `sockaddr_un.sun_path` 共 104 字节，含结尾 NUL，所以路径最多 103 字节。
    static let maxPathBytes = 103

    enum Probe: Equatable {
        case alive
        case dead
        case unknown(Int32)
    }

    static func makeAddress(path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathBytes, !bytes.contains(0) else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxPathBytes + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        return addr
    }

    static func bindSocket(fd: Int32, address: sockaddr_un) -> Int32 {
        var addr = address
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func connectSocket(fd: Int32, address: sockaddr_un) -> Int32 {
        var addr = address
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func setNonBlocking(_ fd: Int32, _ on: Bool) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK))
    }

    static func setCloseOnExec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func setNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setSendTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// 连一下现有 socket 文件，判断是否有进程在监听。
    static func probe(path: String) -> Probe {
        guard let addr = makeAddress(path: path) else { return .unknown(ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unknown(errno) }
        defer { close(fd) }
        setNonBlocking(fd, true)
        if connectSocket(fd: fd, address: addr) == 0 { return .alive }
        switch errno {
        case ECONNREFUSED, ENOENT: return .dead
        case EAGAIN, EINPROGRESS: return .alive // 监听队列已满，说明有进程在监听
        default: return .unknown(errno)
        }
    }

    @discardableResult
    static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }
}
