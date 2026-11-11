import Foundation

public struct ListeningPort: Equatable, Hashable, Sendable {
    public var pid: Int32
    public var command: String
    public var port: Int
    public var address: String

    public init(pid: Int32, command: String, port: Int, address: String) {
        self.pid = pid
        self.command = command
        self.port = port
        self.address = address
    }
}

/// 进程树 / 命令行 / 监听端口扫描。进程表与外部命令都可注入。
public struct ProcessScanner: Sendable {
    public let table: ProcessTable
    public let runner: CommandRunner
    public let clock: Clock

    public init(table: ProcessTable = LibprocProcessTable(), runner: CommandRunner, clock: Clock = SystemClock()) {
        self.table = table
        self.runner = runner
        self.clock = clock
    }

    public func snapshot() -> ProcessSnapshot {
        var processes: [Int32: ProcessRecord] = [:]
        for pid in table.allPIDs() {
            if let record = table.record(for: pid) { processes[pid] = record }
        }
        return ProcessSnapshot(takenAt: clock.now(), processes: processes, commandLines: commandLines())
    }

    /// `ps` 取完整命令行；失败时返回空，不影响其他判断。
    func commandLines() -> [Int32: String] {
        guard let result = try? runner.run(["ps", "-axww", "-o", "pid=,command="], cwd: nil),
              result.status == 0 else { return [:] }
        return Self.parsePS(result.stdout)
    }

    static func parsePS(_ output: String) -> [Int32: String] {
        var map: [Int32: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: { $0 == " " })
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            map[pid] = String(trimmed[space...]).trimmingCharacters(in: .whitespaces)
        }
        return map
    }

    public func listeningPorts() throws -> [ListeningPort] {
        let result = try runner.run(["lsof", "-iTCP", "-sTCP:LISTEN", "-nP", "-F", "pcn"], cwd: nil)
        // lsof 没有匹配项时退出码为 1 且无输出，不是错误
        guard result.status == 0 || result.stdout.isEmpty == false else { return [] }
        return Self.parseLsof(result.stdout)
    }

    /// 解析 `lsof -F pcn`：p<pid> c<command> n<addr:port>，同一 p 下可有多个 n。
    static func parseLsof(_ output: String) -> [ListeningPort] {
        var ports: [ListeningPort] = []
        var seen: Set<ListeningPort> = []
        var pid: Int32?
        var command = ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value)
                command = ""
            case "c":
                command = value
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                let entry = ListeningPort(pid: pid, command: command, port: port, address: String(value[..<colon]))
                if seen.insert(entry).inserted { ports.append(entry) }
            default:
                continue
            }
        }
        return ports
    }
}
