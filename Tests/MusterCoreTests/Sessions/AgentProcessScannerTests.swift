import Foundation
import Testing
@testable import MusterCore

@Suite struct AgentProcessScannerTests {
    @Test func matchesAgentExecutablesOnly() {
        #expect(AgentProcessScanner.kind(forArgs: ["/usr/local/bin/claude"]) == .claude)
        #expect(AgentProcessScanner.kind(forArgs: ["node", "/x/node_modules/@anthropic-ai/claude-code/cli.js"]) == .claude)
        #expect(AgentProcessScanner.kind(forArgs: ["/opt/homebrew/bin/codex"]) == .codex)
        #expect(AgentProcessScanner.kind(forArgs: ["node", "/x/@openai/codex/bin/codex.js"]) == .codex)
        #expect(AgentProcessScanner.kind(forArgs: ["node", "/x/pi-coding-agent/dist/cli.js"]) == .pi)
        #expect(AgentProcessScanner.kind(forArgs: ["/x/bin/cursor-agent", "--serve"]) == .cursor)
        #expect(AgentProcessScanner.kind(forArgs: ["node", "/x/@google/gemini-cli/dist/index.js"]) == .gemini)

        #expect(AgentProcessScanner.kind(forArgs: ["/usr/bin/vim", "/Users/x/.claude/settings.json"]) == nil)
        #expect(AgentProcessScanner.kind(forArgs: ["grep", "claude"]) == nil)
        #expect(AgentProcessScanner.kind(forArgs: ["node", "/x/whatever.js"]) == nil)
    }

    /// 起一个假 `claude` 进程，端到端验证 cwd 和启动时间的读取。
    @Test func readsCwdAndStartTimeOfLiveProcess() throws {
        let tree = try TempTree()
        // 符号链接让 argv[0] 就叫 claude；脚本会被 /bin/sh 接管，ps 里看不到原名
        let bin = tree.path("claude")
        try FileManager.default.createSymbolicLink(atPath: bin, withDestinationPath: "/bin/sleep")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["30"]
        process.currentDirectoryURL = URL(fileURLWithPath: tree.root)
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        var mine: Session?
        for _ in 0..<20 where mine == nil {
            Thread.sleep(forTimeInterval: 0.1)
            mine = AgentProcessScanner().scan().first { $0.pid == process.processIdentifier }
        }
        let session = try #require(mine)
        #expect(session.agent == .claude)
        #expect(URL(fileURLWithPath: session.cwd).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: tree.root).resolvingSymlinksInPath().path)
        #expect(session.state == .unknown)
        #expect(abs(session.startedAt.timeIntervalSinceNow) < 60)
    }
}
