import Foundation
import Testing
@testable import MusterCore

@Suite struct TerminalJumperTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func session(pid: Int32? = 100, cwd: String = "/work/proj") -> Session {
        Session(id: "s1", agent: .claude, cwd: cwd, pid: pid, pidStartTime: t0, startedAt: t0)
    }

    func record(pid: Int32, cwd: String, name: String = "claude", start: Date? = nil) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: 1, startTime: start ?? t0, cwd: cwd, name: name)
    }

    func runner(
        ttyStatus: Int32 = 0, tty: String = "ttys005\n",
        terminalRunning: Bool = true, iTermRunning: Bool = false,
        focusResult: String = "ok"
    ) -> CleanupStubRunner {
        CleanupStubRunner { argv, _ in
            if argv.first == "ps" { return CommandResult(status: ttyStatus, stdout: tty) }
            let script = argv.last ?? ""
            if script.contains("is running") {
                let running = script.contains("\"Terminal\"") ? terminalRunning : iTermRunning
                return CommandResult(status: 0, stdout: running ? "true\n" : "false\n")
            }
            if script.contains("\"Terminal\"") && !terminalRunning { return CommandResult(status: 0, stdout: "not-found") }
            if script.contains("\"iTerm2\"") && !iTermRunning { return CommandResult(status: 0, stdout: "not-found") }
            if script.contains("\"iTerm\"") && !iTermRunning { return CommandResult(status: 0, stdout: "not-found") }
            return CommandResult(status: 0, stdout: focusResult)
        }
    }

    @Test func focusesTerminalTabByTTY() {
        let table = CleanupStubTable([record(pid: 100, cwd: "/work/proj")])
        let runner = runner()
        let result = TerminalJumper(table: table, runner: runner, log: { _ in }).jump(to: session())

        #expect(result == .focused(app: "Terminal", tty: "ttys005"))
        #expect(runner.calls.contains { $0 == ["ps", "-o", "tty=", "-p", "100"] })
        #expect(runner.calls.contains { $0.last?.contains("/dev/ttys005") == true })
    }

    @Test func fallsBackToCwdAndAgentWhenSessionPIDIsStale() {
        let table = CleanupStubTable([
            record(pid: 100, cwd: "/somewhere/else"),
            record(pid: 200, cwd: "/work/proj"),
        ])
        let runner = runner()
        let result = TerminalJumper(table: table, runner: runner, log: { _ in }).jump(to: session())

        #expect(result == .focused(app: "Terminal", tty: "ttys005"))
        #expect(runner.calls.first(where: { $0.first == "ps" })?[4] == "200")
    }

    @Test func stalePIDWithDifferentStartTimeIsNotTrusted() {
        let table = CleanupStubTable([
            record(pid: 100, cwd: "/work/proj", start: t0.addingTimeInterval(500)),
            record(pid: 200, cwd: "/work/proj"),
        ])
        let runner = runner()
        let result = TerminalJumper(table: table, runner: runner, log: { _ in }).jump(to: session())

        #expect(result == .focused(app: "Terminal", tty: "ttys005"))
        #expect(runner.calls.first(where: { $0.first == "ps" })?[4] == "200")
    }

    @Test func usesITermWhenTerminalIsNotRunning() {
        let table = CleanupStubTable([record(pid: 100, cwd: "/work/proj")])
        let result = TerminalJumper(
            table: table, runner: runner(terminalRunning: false, iTermRunning: true), log: { _ in }
        ).jump(to: session())

        #expect(result == .focused(app: "iTerm2", tty: "ttys005"))
    }

    @Test func copiesCdWhenTTYIsMissingOrNoWindowMatches() {
        let table = CleanupStubTable([record(pid: 100, cwd: "/work/proj")])
        let noTTY = TerminalJumper(
            table: table, runner: runner(ttyStatus: 1, tty: ""), log: { _ in }
        ).jump(to: session())
        #expect(noTTY == .copied(command: "cd /work/proj"))

        let noWindow = TerminalJumper(
            table: table, runner: runner(terminalRunning: false), log: { _ in }
        ).jump(to: session())
        #expect(noWindow == .copied(command: "cd /work/proj"))
    }

    @Test func rejectsNonTTYConsole() {
        let table = CleanupStubTable([record(pid: 100, cwd: "/work/proj")])
        let result = TerminalJumper(
            table: table, runner: runner(tty: "console\n"), log: { _ in }
        ).jump(to: session())
        #expect(result == .copied(command: "cd /work/proj"))
    }

    @Test func quotesPathsInClipboardFallback() {
        let table = CleanupStubTable([])
        let result = TerminalJumper(
            table: table, runner: runner(ttyStatus: 1), log: { _ in }
        ).jump(to: session(pid: nil, cwd: "/work/it's here"))

        #expect(result == .copied(command: "cd '/work/it'\\''s here'"))
    }
}
