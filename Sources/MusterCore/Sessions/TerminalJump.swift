import Foundation

/// Where a session's terminal is, if we could find and focus it.
public enum TerminalJumpResult: Equatable, Sendable {
    case focused(app: String, tty: String)
    /// Could not focus a window; the caller should put this command on the clipboard.
    case copied(command: String)
}

/// Focuses the Terminal / iTerm window that owns a session's TTY.
///
/// All external calls are injected so tests never touch a real terminal or automation prompt.
/// A wrong guess is harmless: every failure degrades to a `cd` command for the clipboard.
public struct TerminalJumper: Sendable {
    private let table: ProcessTable
    private let runner: CommandRunner
    private let log: DiagnosticSink

    public init(
        table: ProcessTable = LibprocProcessTable(),
        runner: CommandRunner = CleanupCommandRunner(),
        log: @escaping DiagnosticSink = Diagnostics.default
    ) {
        self.table = table
        self.runner = runner
        self.log = log
    }

    public func jump(to session: Session) -> TerminalJumpResult {
        let fallback = TerminalJumpResult.copied(command: cdCommand(for: session.cwd))
        guard let pid = findPID(for: session), let tty = tty(of: pid) else { return fallback }

        for (app, script) in Self.focusScripts(tty: tty) {
            guard isRunning(app) else { continue }
            guard let output = runAppleScript(script), output == "ok" else { continue }
            return .focused(app: app, tty: tty)
        }
        return fallback
    }

    // MARK: - Process

    private func findPID(for session: Session) -> Int32? {
        if let pid = session.pid, pid > 1,
           let record = table.record(for: pid), cwdMatches(record.cwd, session.cwd),
           identityMatches(session, record) {
            return pid
        }

        let agentName = session.agent.rawValue.lowercased()
        var best: ProcessRecord?
        for pid in table.allPIDs() where pid > 1 && pid != getpid() && pid != session.pid {
            guard let record = table.record(for: pid), cwdMatches(record.cwd, session.cwd) else { continue }
            let haystack = ((record.name ?? "") + " " + (record.executablePath ?? "")).lowercased()
            guard haystack.contains(agentName) else { continue }
            if best == nil || (record.startTime ?? .distantPast) > (best?.startTime ?? .distantPast) {
                best = record
            }
        }
        return best?.pid
    }

    private func cwdMatches(_ actual: String?, _ expected: String) -> Bool {
        guard !expected.isEmpty else { return true }
        guard let actual else { return false }
        return (actual as NSString).standardizingPath == (expected as NSString).standardizingPath
    }

    /// The hook reports the agent's start time; a reused PID in the same folder is not our session.
    private func identityMatches(_ session: Session, _ record: ProcessRecord) -> Bool {
        guard let expected = session.pidStartTime else { return true }
        return startTimesMatch(expected, record.startTime, tolerance: 1)
    }

    private func tty(of pid: Int32) -> String? {
        guard let result = try? runner.run(
            ["ps", "-o", "tty=", "-p", String(pid)], cwd: nil),
              result.status == 0,
              let raw = result.stdout.split(whereSeparator: \.isWhitespace).first else { return nil }
        let tty = String(raw)
        guard tty.hasPrefix("ttys"), tty.count > 4, tty.dropFirst(4).allSatisfy(\.isNumber) else {
            return nil
        }
        return tty
    }

    // MARK: - Terminal apps

    private func isRunning(_ app: String) -> Bool {
        runAppleScript("application \"\(app)\" is running") == "true"
    }

    private func runAppleScript(_ source: String) -> String? {
        guard let result = try? runner.run(["osascript", "-e", source], cwd: nil),
              result.status == 0 else {
            log("terminal jump: osascript failed")
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func focusScripts(tty: String) -> [(String, String)] {
        let device = "/dev/\(tty)"
        let terminal = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(device)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "not-found"
        """
        let iTerm = """
        tell application "APP_NAME"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(device)" then
                            select s
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not-found"
        """
        let iTerm2 = iTerm.replacingOccurrences(of: "APP_NAME", with: "iTerm2")
        let iTermLegacy = iTerm.replacingOccurrences(of: "APP_NAME", with: "iTerm")
        return [("Terminal", terminal), ("iTerm2", iTerm2), ("iTerm", iTermLegacy)]
    }

    // MARK: - Clipboard fallback

    private func cdCommand(for cwd: String) -> String {
        let path = cwd.isEmpty ? "~" : cwd
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@:")
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return "cd \(path)" }
        return "cd '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
