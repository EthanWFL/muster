import Foundation
import Testing
import MusterCore
@testable import Muster

private final class EnvironmentFixture: ProcessTable, CommandRunner, Clock, ProcessSignaller, CleanupLog, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Int32: ProcessRecord] = [:]
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var sent: [CleanupSignal] = []
    private var psCalls = 0
    private var pauseNextPS = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var session: Session { Session(id: "session", agent: .claude, cwd: "/work", pid: 100,
                                  pidStartTime: start, startedAt: start) }
    var signals: [CleanupSignal] { lock.lock(); defer { lock.unlock() }; return sent }
    var scans: Int { lock.lock(); defer { lock.unlock() }; return psCalls }
    func pauseScan() { lock.lock(); defer { lock.unlock() }; pauseNextPS = true }
    func waitForScanEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
    func set(_ pid: Int32, parent: Int32, cpu: Double = 0) {
        lock.lock(); defer { lock.unlock() }
        records[pid] = ProcessRecord(pid: pid, ppid: parent, startTime: start, cwd: "/work",
            name: pid == 100 ? "claude" : "node", executablePath: nil, cpuTimeSeconds: cpu)
    }
    func remove(_ pid: Int32) { lock.lock(); defer { lock.unlock() }; records[pid] = nil }
    func allPIDs() -> [Int32] { lock.lock(); defer { lock.unlock() }; return Array(records.keys) }
    func record(for pid: Int32) -> ProcessRecord? { lock.lock(); defer { lock.unlock() }; return records[pid] }
    func run(_ argv: [String], cwd: String?) throws -> CommandResult {
        if argv.first == "lsof" {
            return CommandResult(status: 0, stdout: record(for: 200) == nil ? "" : "p200\ncnode\nn*:3000\n")
        }
        if argv.first == "ps" {
            lock.lock()
            psCalls += 1
            let pause = pauseNextPS
            pauseNextPS = false
            lock.unlock()
            if pause {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            return CommandResult(status: 0, stdout: "100 claude\n200 node server.js\n")
        }
        return CommandResult(status: 0)
    }
    func send(_ signal: CleanupSignal, to pid: Int32) throws { lock.lock(); defer { lock.unlock() }; sent.append(signal) }
    func log(_ message: String) {}
}

@Suite @MainActor struct EnvironmentModelTests {
    @Test func closingOneSurfaceDoesNotHideAnotherVisibleCleanupPage() async {
        let fixture = EnvironmentFixture()
        let model = EnvironmentModel(runner: fixture, table: fixture, clock: fixture)
        defer { model.stop() }
        let popover = UUID(), window = UUID()
        model.setVisible(true, owner: popover)
        await model.scanTask?.value
        model.setVisible(true, owner: window)
        model.setVisible(true, owner: window)
        #expect(fixture.scans == 1)
        model.setVisible(false, owner: popover)
        #expect(model.isVisible)
        model.setVisible(false, owner: window)
        #expect(!model.isVisible)
        model.setVisible(true, owner: window)
        await model.scanTask?.value
        #expect(fixture.scans == 2)
    }

    @Test func overlappingRefreshRequestsAreCoalesced() async {
        let fixture = EnvironmentFixture()
        fixture.pauseScan()
        let model = EnvironmentModel(runner: fixture, table: fixture, clock: fixture)
        defer { model.stop() }
        model.scan()
        let first = model.scanTask
        let entered = await Task.detached { fixture.waitForScanEntry() }.value
        #expect(entered)
        for _ in 0..<10 { model.scan() }
        #expect(model.isScanning)
        #expect(fixture.scans == 1)
        fixture.release.signal()
        await first?.value
        await model.scanTask?.value
        #expect(fixture.scans == 2)
        #expect(!model.isScanning)
    }

    @Test func continuesSamplingAfterLastParentExits() async {
        let fixture = EnvironmentFixture()
        fixture.set(100, parent: 50)
        fixture.set(200, parent: 100)
        let detector = OrphanDetector(clock: fixture)
        let model = EnvironmentModel(runner: fixture, table: fixture, detector: detector, clock: fixture)
        defer { model.stop() }
        model.sessionsProvider = { [fixture.session] }
        model.sampleOnly()
        await model.scanTask?.value
        #expect(detector.trackedCount == 1)
        fixture.remove(100)
        model.sessionsProvider = { [] }
        for step in 1...32 {
            fixture.advance(10)
            fixture.set(200, parent: 1, cpu: Double(step * 9))
            model.sampleOnly()
            await model.scanTask?.value
        }
        #expect(detector.candidates().map(\.identity.pid) == [200])
        fixture.remove(200)
        model.sampleOnly()
        await model.scanTask?.value
        #expect(detector.trackedCount == 0)
        #expect(!detector.needsSampling(sessions: []))
    }

    @Test func reportWaitsForActualExitAndCannotBeDiscardedEarly() async throws {
        let fixture = EnvironmentFixture()
        fixture.set(100, parent: 50)
        fixture.set(200, parent: 100)
        let executor = CleanupExecutor(table: fixture, runner: fixture, signaller: fixture, clock: fixture, log: fixture)
        let model = EnvironmentModel(runner: fixture, table: fixture, clock: fixture, executor: executor)
        defer { model.stop() }
        model.sessionsProvider = { [fixture.session] }
        model.scan()
        await model.scanTask?.value
        #expect(model.canExecute)
        model.execute()
        await model.executionTask?.value
        #expect(fixture.signals == [.term])
        #expect(model.report?.entries.first?.outcome == .termSent)
        #expect(model.report?.awaitingExit.count == 1)
        #expect(model.forceKillReady.isEmpty)
        model.dismissReport()
        #expect(model.report != nil)
        #expect(!model.canExecute)
        fixture.remove(200)
        await model.reconcileTask?.value
        #expect(model.report?.entries.first?.outcome == .exited)
        #expect(model.report?.awaitingExit.isEmpty == true)
        #expect(model.report?.freedPorts == [3000])
        model.dismissReport()
        #expect(model.report == nil)
        await model.scanTask?.value
    }
}
