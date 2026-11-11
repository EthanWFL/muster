import Testing
import Foundation
import MusterProtocol
@testable import MusterCore

@Suite struct ToolSummaryTests {
    @Test func bashShowsCommand() {
        #expect(ToolSummary.line(tool: "Bash", input: bashInput("rm -rf ./build")) == "Bash: rm -rf ./build")
    }

    @Test func extraWhitespaceIsCollapsed() {
        #expect(ToolSummary.line(tool: "Bash", input: bashInput("rm   -rf    ./build")) == "Bash: rm -rf ./build")
    }

    @Test func editShowsRelativePath() {
        let input: [String: JSONValue] = ["file_path": .string("/tmp/proj/src/app.ts")]
        #expect(ToolSummary.line(tool: "Edit", input: input, cwd: "/tmp/proj") == "Edit: src/app.ts")
        #expect(ToolSummary.line(tool: "Edit", input: input) == "Edit: /tmp/proj/src/app.ts")
    }

    @Test func pathOutsideCwdStaysAbsolute() {
        let input: [String: JSONValue] = ["file_path": .string("/etc/hosts")]
        #expect(ToolSummary.line(tool: "Read", input: input, cwd: "/tmp/proj") == "Read: /etc/hosts")
    }

    @Test func similarPrefixCwdIsNotStripped() {
        let input: [String: JSONValue] = ["file_path": .string("/tmp/project2/a.ts")]
        #expect(ToolSummary.line(tool: "Edit", input: input, cwd: "/tmp/proj") == "Edit: /tmp/project2/a.ts")
    }

    @Test func grepShowsPatternAndPath() {
        let input: [String: JSONValue] = ["pattern": .string("TODO"), "path": .string("/tmp/proj/src")]
        #expect(ToolSummary.line(tool: "Grep", input: input, cwd: "/tmp/proj") == "Grep: TODO in src")
    }

    @Test func missingDetailFallsBackToToolName() {
        #expect(ToolSummary.line(tool: "Mystery", input: [:]) == "Mystery")
        #expect(ToolSummary.line(tool: "Bash", input: [:]) == "Bash")
    }

    @Test func multilineCommandIsOneLine() {
        let s = ToolSummary.line(tool: "Bash", input: bashInput("echo a\nrm -rf x"))
        #expect(!s.contains("\n"))
        #expect(s.contains("rm -rf x"))
    }

    @Test func controlCharactersAreStripped() {
        let s = ToolSummary.line(tool: "Bash", input: bashInput("echo \u{1B}[31mred\u{7}"))
        #expect(!s.unicodeScalars.contains { $0.value < 0x20 })
    }

    @Test func longCommandIsClipped() {
        let s = ToolSummary.line(tool: "Bash", input: bashInput(String(repeating: "x", count: 500)), maxLength: 50)
        #expect(s.count == 50)
        #expect(s.hasSuffix("…"))
    }

    @Test func aliasedShellToolsShowAsBash() {
        #expect(ToolSummary.line(tool: "run_terminal_cmd", input: bashInput("ls")) == "Bash: ls")
    }
}
