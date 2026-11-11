import MusterProtocol
import Darwin
import Foundation

// muster-hook: Claude Code PreToolUse hook client.
// 任何失败（stdin 非法、连不上、超时、回包非法）都按「无决策」处理：无输出、exit 0。
// 这是 fail-safe（回落到 agent 原生提示），绝不能变成 fail-open（R2）。

/// 本地保险超时：app 侧 ttl 之后再多等 5 秒。测试可用环境变量覆盖。
func localTimeoutMs() -> Int {
    if let raw = ProcessInfo.processInfo.environment["MUSTER_HOOK_TIMEOUT_MS"],
       let ms = Int(raw), ms > 0 {
        return ms
    }
    return Wire.defaultTTLms + 5_000
}

func readAllStdin(limit: Int) -> Data? {
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(STDIN_FILENO, &chunk, chunk.count)
        if n > 0 {
            data.append(chunk, count: n)
            if data.count > limit { return nil }
        } else if n == 0 {
            return data
        } else if errno == EINTR {
            continue
        } else {
            return nil
        }
    }
}

func nowMs() -> Int {
    Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
}

/// 非阻塞 connect，最多等 `timeoutMs`。失败返回 -1。
func connectSocket(path: String, timeoutMs: Int) -> Int32 {
    guard var addr = SocketPath.makeAddress(path: path) else { return -1 }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if rc != 0 {
        guard errno == EINPROGRESS || errno == EAGAIN else { close(fd); return -1 }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let r = poll(&p, 1, Int32(timeoutMs))
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard r > 0, getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else {
            close(fd)
            return -1
        }
    }
    return fd
}

func writeAll(fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        var offset = 0
        while offset < raw.count {
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&p, 1, 5_000)
            if pr < 0 { if errno == EINTR { continue }; return false }
            if pr == 0 { return false }
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n > 0 { offset += n; continue }
            if n < 0, errno == EINTR || errno == EAGAIN { continue }
            return false
        }
        return true
    }
}

/// 读到第一个换行为止；超时、EOF、超长都返回 nil。
func readLine(fd: Int32, timeoutMs: Int) -> Data? {
    let deadline = nowMs() + timeoutMs
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        if let idx = buffer.firstIndex(of: 0x0A) {
            return Data(buffer[buffer.startIndex..<idx])
        }
        if buffer.count > Wire.maxLineBytes { return nil }
        let remaining = deadline - nowMs()
        if remaining <= 0 { return nil }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&p, 1, Int32(min(remaining, Int(Int32.max))))
        if r < 0 { if errno == EINTR { continue }; return nil }
        if r == 0 { continue }
        let n = read(fd, &chunk, chunk.count)
        if n > 0 {
            buffer.append(chunk, count: n)
        } else if n == 0 {
            return nil
        } else if errno == EINTR || errno == EAGAIN {
            continue
        } else {
            return nil
        }
    }
}

/// Nearest ancestor whose name/path contains "claude". The hook itself is a child of a short-lived
/// shell, so reporting `getppid()` would make the session look dead as soon as the hook exits.
func agentProcess() -> (pid: Int32, startedAt: Double)? {
    var pid = getppid()
    for _ in 0..<8 {
        guard pid > 1 else { return nil }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }

        let name = withUnsafePointer(to: &bsd.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : ""

        if name.lowercased().contains("claude") || path.lowercased().contains("claude") {
            let started = Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000
            return (pid, started)
        }
        pid = Int32(bitPattern: bsd.pbi_ppid)
    }
    return nil
}

/// 返回 (decision, reason)；任何异常返回 (nil, nil)。
func askDaemon() -> (WireDecision?, String?) {
    guard let stdin = readAllStdin(limit: HookRequestBuilder.stdinLimitBytes) else { return (nil, nil) }
    let process = agentProcess()
    guard let request = HookRequestBuilder.build(
        stdin: stdin, pid: process?.pid, pidStartedAt: process?.startedAt),
          let line = try? WireCodec.encodeLine(request) else {
        return (nil, nil)
    }
    let env = ProcessInfo.processInfo.environment
    let path = SocketPath.resolve(environment: env)
    let fd = connectSocket(path: path, timeoutMs: 2_000)
    guard fd >= 0 else { return (nil, nil) }
    defer { close(fd) }

    guard writeAll(fd: fd, data: line),
          let reply = readLine(fd: fd, timeoutMs: localTimeoutMs()),
          let response = try? WireCodec.decode(WireResponse.self, line: reply),
          response.v == Wire.version,
          response.type == "decision",
          response.id == request.id else {
        return (nil, nil)
    }
    return (response.decision, response.reason)
}

func emit(_ text: String, to fd: Int32) {
    guard !text.isEmpty else { return }
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { break }
    }
}

let (decision, reason) = askDaemon()
let output = HookOutput.make(decision: decision, reason: reason)
emit(output.stdout, to: STDOUT_FILENO)
emit(output.stderr, to: STDERR_FILENO)
exit(output.exitCode)
