import Foundation

/// 扫本机正在跑的 agent 进程：每个进程就是一条"开着的会话"。
///
/// 命令行来自 `ps`，cwd 和启动时间来自进程表；读不到 cwd 的（别人的进程）直接跳过。
public struct AgentProcessScanner: Sendable {
    public let table: ProcessTable
    public let runner: CommandRunner

    public init(table: ProcessTable = LibprocProcessTable(), runner: CommandRunner = CleanupCommandRunner()) {
        self.table = table
        self.runner = runner
    }

    public func scan() -> [Session] {
        guard let result = try? runner.run(["ps", "-axww", "-o", "pid=,command="], cwd: nil),
              result.status == 0 else { return [] }
        return ProcessScanner.parsePS(result.stdout).compactMap { pid, command in
            guard let kind = Self.kind(forArgs: command.split(separator: " ").map(String.init)),
                  let record = table.record(for: pid), let cwd = record.cwd else { return nil }
            let started = record.startTime ?? Date()
            return Session(
                id: "proc-\(pid)", agent: kind, cwd: cwd, pid: pid, pidStartTime: record.startTime,
                startedAt: started, lastActivityAt: started, state: .running)
        }
    }

    /// 只认可执行名，外加 node 跑脚本时认包路径，避免把 `vim .../claude/…` 当成 agent。
    static func kind(forArgs args: [String]) -> AgentKind? {
        guard let first = args.first else { return nil }
        switch (first as NSString).lastPathComponent {
        case "claude": return .claude
        case "codex": return .codex
        case "pi": return .pi
        case "dsh": return .dsh
        case "gemini": return .gemini
        case "cursor-agent": return .cursor
        case "opencode": return .opencode
        case "node":
            let script = args.count > 1 ? args[1] : ""
            if script.contains("/claude-code/") { return .claude }
            if script.contains("/@openai/codex/") { return .codex }
            if script.contains("/pi-coding-agent/") { return .pi }
            if script.contains("/gemini-cli/") { return .gemini }
            return nil
        default:
            return nil
        }
    }
}
