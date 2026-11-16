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
        var records: [Int32: ProcessRecord] = [:]
        var unavailable = Set<Int32>()
        func record(_ pid: Int32) -> ProcessRecord? {
            if let cached = records[pid] { return cached }
            guard !unavailable.contains(pid), let found = table.record(for: pid) else {
                unavailable.insert(pid)
                return nil
            }
            records[pid] = found
            return found
        }
        return ProcessScanner.parsePS(result.stdout).compactMap { pid, command in
            guard let kind = Self.kind(forArgs: command.split(separator: " ").map(String.init)),
                  let process = record(pid), let cwd = process.cwd else { return nil }
            let started = process.startTime ?? Date()
            return Session(
                id: "proc-\(pid)-\(Int(started.timeIntervalSince1970))", agent: kind, cwd: cwd, pid: pid, pidStartTime: process.startTime,
                startedAt: started, lastActivityAt: started, state: .unknown,
                client: SessionClient.detect(for: process, record: record))
        }
    }

    /// 只认可执行名，外加 node 跑脚本时认包路径，避免把 `vim .../claude/…` 当成 agent。
    static func kind(forArgs args: [String]) -> AgentKind? {
        AgentRegistry.kind(forArgs: args)
    }
}
