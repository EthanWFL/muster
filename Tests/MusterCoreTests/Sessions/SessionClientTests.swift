import Foundation
import Testing
@testable import MusterCore

@Suite struct SessionClientTests {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ pid: Int32, parent: Int32, path: String, age: TimeInterval = 0) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: parent, startTime: time.addingTimeInterval(-age), cwd: "/work",
                      executablePath: path)
    }

    @Test func warpPanesInSameDirectoryFollowShellIdentity() throws {
        let tree = try TempTree()
        let directory = URL(fileURLWithPath: tree.root)
        let first = String(repeating: "a", count: 32), second = String(repeating: "b", count: 32)
        let warp = record(10, parent: 1, path: "/Applications/Warp.app/Contents/MacOS/stable", age: 20)
        func detect(_ pid: Int32, age: TimeInterval = 10) -> SessionClient? {
            let shell = record(pid, parent: 10, path: "/bin/zsh", age: age)
            return SessionClient.detect(for: record(42, parent: pid, path: "/usr/bin/pi"), warpPaneDirectory: directory) {
                $0 == pid ? shell : warp
            }
        }
        let epoch = Int(time.timeIntervalSince1970) - 10
        for (pid, id) in [(20, first), (21, second)] {
            try id.write(to: directory.appendingPathComponent("\(pid).\(epoch)"), atomically: true, encoding: .utf8)
            #expect(detect(Int32(pid))?.paneURL?.absoluteString == "warp://session/" + id)
        }
        #expect(detect(20, age: 1)?.paneURL == nil)
        try "bad/url".write(to: directory.appendingPathComponent("20.\(epoch)"), atomically: true, encoding: .utf8)
        #expect(detect(20)?.paneURL == nil)
    }

    @Test func shellAncestorIdentifiesWarpInsteadOfTheAgent() {
        let agent = record(42, parent: 20, path: "/usr/bin/pi")
        let parents = [20: record(20, parent: 10, path: "/bin/zsh", age: 10),
                       10: record(10, parent: 1, path: "/Applications/Warp.app/Contents/MacOS/stable", age: 20)]
        let client = SessionClient.detect(for: agent) { parents[Int($0)] }
        #expect(client == SessionClient(name: "Warp", bundlePath: "/Applications/Warp.app"))
    }

    @Test func recognizesDesktopClientsAndEditorHelpersWithSpacesInThePath() {
        let cases = [
            ("/Applications/Codex.app/Contents/MacOS/Codex", "Codex", "/Applications/Codex.app"),
            ("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", "ChatGPT", "/Applications/ChatGPT.app"),
            ("/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)", "VS Code", "/Applications/Visual Studio Code.app"),
            ("/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper", "Cursor", "/Applications/Cursor.app"),
            ("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", "Terminal", "/System/Applications/Utilities/Terminal.app"),
            ("/Applications/iTerm.app/Contents/MacOS/iTerm2", "iTerm", "/Applications/iTerm.app")
        ]
        for (path, name, bundle) in cases {
            let client = SessionClient.detect(for: record(42, parent: 20, path: "/usr/bin/codex")) { _ in
                record(20, parent: 1, path: path, age: 10)
            }
            #expect(client == SessionClient(name: name, bundlePath: bundle))
        }
    }

    @Test func anAppBundledAgentLaunchedFromATerminalStillBelongsToTheTerminal() {
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let parents = [20: record(20, parent: 10, path: bundled, age: 10),
                       10: record(10, parent: 1, path: "/Applications/Warp.app/Contents/MacOS/stable", age: 20)]
        #expect(SessionClient.detect(for: record(42, parent: 20, path: bundled)) { parents[Int($0)] }?.name == "Warp")
    }

    @Test func multiplexerSSHAndMissingAncestryDoNotGuessAClient() {
        for executable in ["tmux", "screen", "sshd"] {
            let parents = [20: record(20, parent: 10, path: "/usr/bin/" + executable, age: 10),
                           10: record(10, parent: 1, path: "/Applications/Warp.app/Contents/MacOS/stable", age: 20)]
            #expect(SessionClient.detect(for: record(42, parent: 20, path: "/usr/bin/pi")) { parents[Int($0)] } == nil)
        }
        #expect(SessionClient.detect(for: record(42, parent: 20, path: "/usr/bin/pi")) { _ in nil } == nil)
    }

    @Test func cyclesAndReusedParentPIDsAreRejected() {
        #expect(SessionClient.detect(for: record(42, parent: 20, path: "/usr/bin/pi")) { _ in
            record(20, parent: 42, path: "/bin/zsh", age: 10)
        } == nil)
        #expect(SessionClient.detect(for: record(42, parent: 20, path: "/usr/bin/pi", age: 100)) { _ in
            record(20, parent: 1, path: "/Applications/Warp.app/Contents/MacOS/stable")
        } == nil)
    }

    @Test func processScanAttachesClientWithoutChangingAgentClassification() {
        let agent = record(42, parent: 20, path: "/usr/bin/claude")
        let parent = record(20, parent: 1, path: "/Applications/Warp.app/Contents/MacOS/stable", age: 10)
        let scanner = AgentProcessScanner(table: ClientTable(records: [42: agent, 20: parent]), runner: ClientRunner())
        let sessions = scanner.scan()
        #expect(sessions.count == 1 && sessions.first?.agent == .claude)
        #expect(sessions.first?.client?.name == "Warp")
    }
}

private struct ClientTable: ProcessTable {
    let records: [Int32: ProcessRecord]
    func allPIDs() -> [Int32] { Array(records.keys) }
    func record(for pid: Int32) -> ProcessRecord? { records[pid] }
}

private struct ClientRunner: CommandRunner {
    func run(_ argv: [String], cwd: String?) throws -> CommandResult {
        CommandResult(status: 0, stdout: "42 /usr/bin/claude\n")
    }
}
