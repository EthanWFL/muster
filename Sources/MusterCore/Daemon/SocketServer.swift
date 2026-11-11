import MusterProtocol
import Darwin
import Foundation

public enum SocketServerError: Error, Equatable {
    case invalidPath
    case pathTooLong(bytes: Int)
    case alreadyStarted
    /// 另一个进程正在监听这个路径。
    case addressInUse(String)
    /// 路径上存在一个不是 socket 的文件，拒绝删除。
    case notASocket(String)
    case directoryNotOwned(String)
    case systemCall(String, errno: Int32)
}

/// Unix domain socket 服务端，NDJSON 协议见 `MusterProtocol`。
///
/// 线程模型：一个 accept 线程 + 每个连接一个读线程。读线程在 request 送出后继续阻塞在
/// `poll/read` 上，对端关闭即视为取消。handler 的响应由 Swift Task 写回。
/// 一个连接只承载一个 request。
public final class SocketServer: @unchecked Sendable {
    public let path: String
    /// 收到完整请求行之前的最长等待时间；超时即断开，避免空连接占线程。
    public var requestReadTimeout: TimeInterval = 10
    /// 同时存在的连接上限，超过的直接关闭。
    public var maxConnections = 256

    let handler: RequestHandling
    let allowedUID: uid_t
    let lock = NSLock()
    private var started = false
    private var stopped = false
    private var listenFD: Int32 = -1
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var socketIdentity: (dev: dev_t, ino: ino_t)?
    private var acceptDone: DispatchSemaphore?
    var connections: [ObjectIdentifier: Connection] = [:]

    public init(path: String, handler: RequestHandling, allowedUID: uid_t = geteuid()) {
        self.path = path
        self.handler = handler
        self.allowedUID = allowedUID
    }

    deinit { stop() }

    // MARK: - Lifecycle

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { throw SocketServerError.alreadyStarted }

        let bytes = path.utf8.count
        guard bytes > 0, !path.utf8.contains(0) else { throw SocketServerError.invalidPath }
        guard bytes <= SocketPath.maxBytes, let address = SocketPath.makeAddress(path: path) else {
            throw SocketServerError.pathTooLong(bytes: bytes)
        }

        try prepareDirectory()
        try removeStaleSocketIfNeeded()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketServerError.systemCall("socket", errno: errno) }
        UnixSocket.setCloseOnExec(fd)
        UnixSocket.setNoSigPipe(fd)

        guard UnixSocket.bindSocket(fd: fd, address: address) == 0 else {
            let e = errno
            close(fd)
            throw e == EADDRINUSE ? SocketServerError.addressInUse(path) : SocketServerError.systemCall("bind", errno: e)
        }
        guard chmod(path, 0o600) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw SocketServerError.systemCall("chmod", errno: e)
        }
        guard listen(fd, 128) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw SocketServerError.systemCall("listen", errno: e)
        }
        var st = stat()
        if stat(path, &st) == 0 { socketIdentity = (st.st_dev, st.st_ino) }

        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw SocketServerError.systemCall("pipe", errno: e)
        }
        UnixSocket.setCloseOnExec(pipeFDs[0])
        UnixSocket.setCloseOnExec(pipeFDs[1])

        listenFD = fd
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
        started = true

        let done = DispatchSemaphore(value: 0)
        acceptDone = done
        let thread = Thread { [self] in
            acceptLoop(listenFD: fd, wakeRead: pipeFDs[0])
            done.signal()
        }
        thread.name = "muster.accept"
        thread.start()
    }

    /// 停止监听、删除 socket 文件，并断开所有连接（未应答的请求会收到取消回调）。幂等。
    public func stop() {
        lock.lock()
        guard started, !stopped else { lock.unlock(); return }
        stopped = true
        let done = acceptDone
        let wake = wakeWrite
        let active = Array(connections.values)
        lock.unlock()

        var byte: UInt8 = 1
        _ = write(wake, &byte, 1)
        done?.wait()

        lock.lock()
        close(wakeRead)
        close(wakeWrite)
        wakeRead = -1
        wakeWrite = -1
        lock.unlock()

        var st = stat()
        if let id = socketIdentity, stat(path, &st) == 0, st.st_dev == id.dev, st.st_ino == id.ino {
            unlink(path)
        }
        for c in active { c.shutdownForStop() }
    }

    // MARK: - Startup helpers

    private func prepareDirectory() throws {
        let dir = (path as NSString).deletingLastPathComponent
        var st = stat()
        if stat(dir, &st) != 0 {
            do {
                try FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw SocketServerError.systemCall("mkdir", errno: errno)
            }
            guard stat(dir, &st) == 0 else { throw SocketServerError.systemCall("stat", errno: errno) }
        }
        guard st.st_uid == geteuid() else { throw SocketServerError.directoryNotOwned(dir) }
        if st.st_mode & 0o777 != 0o700 {
            guard chmod(dir, 0o700) == 0 else { throw SocketServerError.systemCall("chmod", errno: errno) }
        }
    }

    /// 文件存在时：必须是 socket，连一下，活着就报错，死了才删。
    private func removeStaleSocketIfNeeded() throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        guard st.st_mode & S_IFMT == S_IFSOCK else { throw SocketServerError.notASocket(path) }
        switch UnixSocket.probe(path: path) {
        case .alive:
            throw SocketServerError.addressInUse(path)
        case .dead:
            unlink(path)
        case .unknown(let e):
            throw SocketServerError.systemCall("probe", errno: e)
        }
    }

    // MARK: - Accept

    private func acceptLoop(listenFD: Int32, wakeRead: Int32) {
        defer { close(listenFD) }
        while true {
            var fds = [
                pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            let r = poll(&fds, 2, -1)
            if r < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }

            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 { continue }
            UnixSocket.setCloseOnExec(cfd)
            UnixSocket.setNoSigPipe(cfd)
            UnixSocket.setSendTimeout(cfd, seconds: 5)

            let conn = Connection(fd: cfd)
            lock.lock()
            let accept = !stopped && connections.count < maxConnections
            if accept { connections[ObjectIdentifier(conn)] = conn }
            lock.unlock()
            guard accept else { close(cfd); continue }

            let thread = Thread { [self] in
                serve(conn)
                lock.lock()
                connections[ObjectIdentifier(conn)] = nil
                lock.unlock()
            }
            thread.name = "muster.conn"
            thread.start()
        }
    }
}
