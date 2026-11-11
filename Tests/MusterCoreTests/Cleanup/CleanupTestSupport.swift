import Foundation
@testable import MusterCore

/// 测试替身：进程表、信号发送、日志、时钟、命令执行。全部不碰真实进程。
final class CleanupStubTable: ProcessTable, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Int32: ProcessRecord]

    init(_ list: [ProcessRecord]) {
        records = Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0) })
    }

    func set(_ record: ProcessRecord) {
        lock.lock(); defer { lock.unlock() }
        records[record.pid] = record
    }

    func remove(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        records[pid] = nil
    }

    func allPIDs() -> [Int32] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.keys)
    }

    func record(for pid: Int32) -> ProcessRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[pid]
    }
}

final class CleanupRecordingSignaller: ProcessSignaller, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(signal: CleanupSignal, pid: Int32)] = []

    var calls: [(signal: CleanupSignal, pid: Int32)] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    func send(_ signal: CleanupSignal, to pid: Int32) throws {
        lock.lock(); defer { lock.unlock() }
        sent.append((signal, pid))
    }
}

final class CleanupMemoryLog: CleanupLog, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    func log(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(message)
    }
}

final class CleanupTestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}

final class CleanupStubRunner: CommandRunner, @unchecked Sendable {
    typealias Handler = @Sendable ([String], String?) throws -> CommandResult
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(_ argv: [String], cwd: String?) throws -> CommandResult {
        lock.lock()
        recorded.append(argv)
        lock.unlock()
        return try handler(argv, cwd)
    }
}

/// 一套固定场景：session 根进程 100，其子进程 200（dev server），无关进程 300。
enum CleanupFixture {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let sessionCwd = "/work/proj"

    static let session = Session(
        id: "s1", agent: .claude, cwd: sessionCwd, pid: 100, pidStartTime: t0, startedAt: t0)

    static func record(
        _ pid: Int32, ppid: Int32, start: TimeInterval, cwd: String? = sessionCwd, name: String? = "node",
        cpu: Double? = nil
    ) -> ProcessRecord {
        ProcessRecord(
            pid: pid, ppid: ppid, startTime: t0.addingTimeInterval(start), cwd: cwd, name: name,
            executablePath: nil, cpuTimeSeconds: cpu)
    }

    static func defaultRecords(ownPID: Int32 = 4242) -> [ProcessRecord] {
        [
            record(1, ppid: 0, start: -1000, cwd: "/", name: "launchd"),
            record(50, ppid: 1, start: -500, cwd: "/", name: "zsh"),
            record(100, ppid: 50, start: 0, name: "claude"),
            record(200, ppid: 100, start: 10, name: "node"),
            // 无关进程：cwd 在 session 目录之下，但不在进程树内
            record(300, ppid: 1, start: 20, cwd: sessionCwd + "/sub", name: "node"),
            record(ownPID, ppid: 50, start: 5, cwd: sessionCwd, name: "Muster"),
        ]
    }

    static func score(_ points: Int, session: String = "s1") -> OwnershipScore {
        OwnershipScore(
            sessionID: session, points: points, maxPoints: 100, isUncertain: points < 80, reasons: [])
    }

    static func target(
        pid: Int32, startOffset: TimeInterval, kind: ProcessTarget.Kind = .listener, points: Int = 100,
        inTree: Bool = true, name: String? = "node", commandLine: String? = "node vite.js", ports: [Int] = [3000]
    ) -> ProcessTarget {
        ProcessTarget(
            identity: ProcessIdentity(pid: pid, startTime: t0.addingTimeInterval(startOffset)),
            name: name, commandLine: commandLine, kind: kind, sessionID: "s1", ports: ports,
            score: score(points), inSessionTreeAtPlan: inTree)
    }

    static func item(_ target: ProcessTarget) -> CleanupItem {
        CleanupItem(action: .terminate(target), title: "t")
    }
}

/// 执行器 + 全部替身。
final class CleanupRig: @unchecked Sendable {
    let table: CleanupStubTable
    let signaller = CleanupRecordingSignaller()
    let log = CleanupMemoryLog()
    let clock = CleanupTestClock(CleanupFixture.t0.addingTimeInterval(100))
    let executor: CleanupExecutor
    let ownPID: Int32

    init(records: [ProcessRecord]? = nil, ownPID: Int32 = 4242, runner: CommandRunner? = nil) {
        self.ownPID = ownPID
        table = CleanupStubTable(records ?? CleanupFixture.defaultRecords(ownPID: ownPID))
        executor = CleanupExecutor(
            table: table, runner: runner ?? CleanupStubRunner { _, _ in CommandResult(status: 0) },
            signaller: signaller, clock: clock, log: log, ownPID: ownPID)
    }

    @discardableResult
    func run(
        _ item: CleanupItem, confirmed: Bool = false, sessions: [Session] = [CleanupFixture.session]
    ) -> CleanupOutcome {
        let plan = CleanupPlan(createdAt: CleanupFixture.t0, items: [item])
        let request = CleanupRequest(selected: [item.id], confirmed: confirmed ? [item.id] : [])
        return executor.execute(plan: plan, request: request, sessions: sessions).entries.first?.outcome
            ?? .failed("no entry")
    }
}
