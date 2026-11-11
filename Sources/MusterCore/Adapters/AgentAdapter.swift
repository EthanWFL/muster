import Foundation

public enum AdapterError: Error, Equatable {
    case notInstalled
    case unsupported(String)
    /// 配置文件解析失败或 schema 未知：拒绝写入，不尝试修复
    case unrecognizedConfig(String)
    case io(String)
}

/// 每个 agent 一个实现；业务代码不许内联 agent 特有逻辑。
public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    /// 从落盘文件推断会话；只读，不复制 transcript 内容
    func sessions() throws -> [Session]
    /// 写该 agent 的 hook 配置；必须先备份，且可回滚
    func installHooks() throws
    /// 只移除本工具写入的条目，不整文件还原
    func uninstallHooks() throws
    /// 把决策送回 agent（Claude 上是通过 socket 回写，不是写文件）
    func decide(_ call: ToolCall, _ decision: Decision) throws
}
