import Foundation
import Darwin

/// 清理模块的日志出口。R6 拒绝必须记日志，所以执行器强制持有一个。
public protocol CleanupLog: Sendable {
    func log(_ message: String)
}

public struct NullCleanupLog: CleanupLog {
    public init() {}
    public func log(_ message: String) {}
}

/// 清理只会用到两种信号。用枚举而不是裸 Int32，避免误发其他信号。
public enum CleanupSignal: Equatable, Sendable {
    case term
    case kill

    public var number: Int32 { self == .term ? SIGTERM : SIGKILL }
    public var flag: String { self == .term ? "-TERM" : "-KILL" }
}

/// 信号发送必须经过此协议，测试注入记录型实现，绝不碰真实进程。
public protocol ProcessSignaller: Sendable {
    func send(_ signal: CleanupSignal, to pid: Int32) throws
}

public struct SystemProcessSignaller: ProcessSignaller {
    public init() {}

    public func send(_ signal: CleanupSignal, to pid: Int32) throws {
        // 纵深防御：即使执行器被绕过，真实发送层也不接受危险 pid
        guard pid > 1, pid != getpid() else {
            throw POSIXError(.EPERM)
        }
        if Darwin.kill(pid, signal.number) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
    }
}

/// 目录存在性与占用空间，注入以便测试不依赖真实磁盘。
public protocol CleanupFileSystem: Sendable {
    func directoryExists(_ path: String) -> Bool
    func allocatedSize(of path: String) -> Int64
}

public struct SystemCleanupFileSystem: CleanupFileSystem {
    public init() {}

    public func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public func allocatedSize(of path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// 把命令数组转成可读的 shell 文本。仅用于展示，执行永远走 argv。
func shellQuote(_ arg: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
    if !arg.isEmpty, arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
    return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
