import Darwin
import Foundation

/// socket 路径解析与 `sockaddr_un` 构造，daemon 和 hook 共用。
public enum SocketPath {
    /// `sockaddr_un.sun_path` 共 104 字节，含结尾 NUL，所以路径最多 103 字节（即 < 104）。
    public static let maxBytes = 103
    public static let environmentKey = "MUSTER_SOCK"

    public static func defaultPath(home: String) -> String {
        home + "/Library/Application Support/Muster/agentd.sock"
    }

    /// 环境变量 `MUSTER_SOCK` 优先，否则用默认路径。
    public static func resolve(environment: [String: String], home: String? = nil) -> String {
        if let p = environment[environmentKey], !p.isEmpty { return p }
        return defaultPath(home: home ?? environment["HOME"] ?? NSHomeDirectory())
    }

    /// 路径为空、含 NUL 或超过 `maxBytes` 时返回 nil。
    public static func makeAddress(path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxBytes, !bytes.contains(0) else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxBytes + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        return addr
    }
}
