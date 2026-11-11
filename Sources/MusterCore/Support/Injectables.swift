import Foundation

/// 一切涉及时间、外部命令的代码都通过协议注入，否则 R1/R6 无法稳定测试。
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunner: Sendable {
    /// `argv[0]` 为可执行文件；不经过 shell，参数不做拼接
    func run(_ argv: [String], cwd: String?) throws -> CommandResult
}
