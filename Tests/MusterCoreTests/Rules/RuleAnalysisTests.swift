import Foundation
import Testing
@testable import MusterCore

@Suite struct DuplicateRuleTests {
    @Test func twoDuplicateRulesAreFoundWithBothLineNumbers() async throws {
        let t = try TempTree()
        try t.makeRepo("a")
        try t.makeRepo("b")
        try t.write("a/CLAUDE.md", "# Rules\n\n- Always run the linter before committing changes to the repository.\n")
        try t.write("b/AGENTS.md", "# Agents\n\nSome intro text.\n\n- Always run the linter, before committing changes to the repository!\n")

        let report = try await makeScanner(t).scan()
        #expect(report.duplicates.count == 1)
        let group = try #require(report.duplicates.first)
        #expect(group.entries.map(\.location) == [t.path("a/CLAUDE.md") + ":3", t.path("b/AGENTS.md") + ":5"])
        #expect(group.similarity > 0.8)
    }

    @Test func unrelatedRulesAreNotDuplicates() {
        let a = entry("a/CLAUDE.md", 1, "Always run the linter before committing changes.")
        let b = entry("b/CLAUDE.md", 1, "Database migrations live in the db folder and run at startup.")
        #expect(DuplicateDetector().findDuplicates(in: [a, b]).isEmpty)
    }

    @Test func chineseDuplicatesUseBigrams() {
        let a = entry("a/CLAUDE.md", 2, "所有提交必须通过代码检查并运行单元测试")
        let b = entry("b/CLAUDE.md", 9, "所有提交必须通过代码检查，并运行单元测试。")
        let c = entry("c/CLAUDE.md", 4, "数据库迁移文件放在独立目录并在启动时执行")
        let groups = DuplicateDetector().findDuplicates(in: [a, b, c])
        #expect(groups.count == 1)
        #expect(groups[0].entries.map(\.line) == [2, 9])
    }

    @Test func suggestionIsPlainText() {
        let a = entry("a/CLAUDE.md", 3, "Always run the linter before committing changes.")
        let b = entry("b/CLAUDE.md", 5, "Always run the linter before committing changes.")
        let group = try! #require(DuplicateDetector().findDuplicates(in: [a, b]).first)
        let text = RuleSuggestion.text(for: group)
        #expect(text.contains("a/CLAUDE.md:3"))
        #expect(text.contains("b/CLAUDE.md:5"))
    }
}

@Suite struct StaleReferenceTests {
    @Test func nonexistentPathIsFlaggedAndExistingPathIsNot() async throws {
        let t = try TempTree()
        try t.makeRepo("a")
        try t.write("a/Scripts/build.sh", "#!/bin/sh\n")
        try t.write("a/CLAUDE.md", "# Rules\n\n- Build with `Scripts/build.sh` only.\n- Deploy using `Scripts/deploy-gone.sh` from CI.\n")

        let report = try await makeScanner(t).scan()
        #expect(report.staleReferences.count == 1)
        let ref = try #require(report.staleReferences.first)
        #expect(ref.reference == "Scripts/deploy-gone.sh")
        #expect(ref.kind == .path)
        #expect(ref.line == 4)
        #expect(ref.checkedPaths.contains(t.path("a/Scripts/deploy-gone.sh")))
    }

    @Test func missingCommandIsFlaggedOnlyWithCommandContext() async throws {
        let t = try TempTree()
        try t.makeRepo("a")
        try t.write("a/CLAUDE.md", "- Run `zzznotinstalled` before pushing.\n- Run `make` before pushing.\n- The word `zzzunrelated` is just a name.\n")
        let report = try await makeScanner(t, commands: ["make"]).scan()
        #expect(report.staleReferences.map(\.reference) == ["zzznotinstalled"])
        #expect(report.staleReferences.first?.kind == .command)
    }

    @Test func falseNegativeShapesAreNotFlagged() {
        let spans = [
            "foo.bar", "npm run build", "<placeholder>", "src/**/*.ts", "*.swift", "https://example.com/a.js",
            "--verbose", "-rf", "~/notes/x.md", "/etc/hosts", "$HOME/x.sh", "git commit -m msg",
            "docs/<name>.md", "path/to/file.txt", "github.com/foo/bar", "../outside/x.md", "{a,b}/c.md",
            "v1.2.3", "README",
        ]
        let text = spans.map { "- Note `\($0)` here." }.joined(separator: "\n")
        let e = entry("a/CLAUDE.md", 1, text)
        let checker = RefChecker(fileSystem: DefaultRuleFileSystem(), commands: FakeCommands(available: []))
        #expect(checker.check(e).isEmpty)
    }

    @Test func injectedFileSystemIsUsed() {
        struct NothingExists: RuleFileSystem {
            func listDirectory(atPath path: String) throws -> [RuleDirectoryEntry] { [] }
            func stat(atPath path: String) -> RuleFileStat? { nil }
            func readText(atPath path: String) throws -> String { "" }
            func exists(atPath path: String) -> Bool { false }
            func isExecutable(atPath path: String) -> Bool { false }
            func realPath(_ path: String) -> String { path }
        }
        struct EverythingExists: RuleFileSystem {
            func listDirectory(atPath path: String) throws -> [RuleDirectoryEntry] { [] }
            func stat(atPath path: String) -> RuleFileStat? { nil }
            func readText(atPath path: String) throws -> String { "" }
            func exists(atPath path: String) -> Bool { true }
            func isExecutable(atPath path: String) -> Bool { true }
            func realPath(_ path: String) -> String { path }
        }
        let e = entry("/r/CLAUDE.md", 1, "See `docs/guide.md` for details.")
        let none = RefChecker(fileSystem: NothingExists(), commands: FakeCommands(available: []))
        let all = RefChecker(fileSystem: EverythingExists(), commands: FakeCommands(available: []))
        #expect(none.check(e).count == 1)
        #expect(all.check(e).isEmpty)
    }
}

@Suite struct ContradictionTests {
    @Test func pnpmVersusNpmAcrossReposIsDetected() async throws {
        let t = try TempTree()
        try t.makeRepo("a")
        try t.makeRepo("b")
        try t.write("a/CLAUDE.md", "- Always use pnpm for installing dependencies.\n")
        try t.write("b/CLAUDE.md", "# B\n\n- Always use npm for installing dependencies.\n")

        let report = try await makeScanner(t).scan()
        let c = try #require(report.contradictions.first { $0.topicID == "js-package-manager" })
        #expect(c.kind == .conflictingChoice)
        let locations = c.positions.flatMap(\.entries).map(\.location)
        #expect(locations.contains(t.path("a/CLAUDE.md") + ":1"))
        #expect(locations.contains(t.path("b/CLAUDE.md") + ":3"))
    }

    @Test func requireVersusForbidInEnglishAndChinese() {
        let det = ContradictionDetector()
        let en = det.findContradictions(in: [
            entry("a/CLAUDE.md", 1, "You must use yarn.", repo: "a"),
            entry("b/CLAUDE.md", 1, "Never use yarn in this repo.", repo: "b"),
        ])
        #expect(en.first?.kind == .requireVersusForbid)

        let zh = det.findContradictions(in: [
            entry("a/CLAUDE.md", 1, "必须使用 pnpm 安装依赖", repo: "a"),
            entry("b/CLAUDE.md", 7, "禁止使用 pnpm，统一用 npm", repo: "b"),
        ])
        #expect(!zh.isEmpty)
        #expect(zh.contains { $0.positions.flatMap(\.entries).map(\.line).contains(7) })
    }

    @Test func tabsVersusSpacesIsDetected() {
        let found = ContradictionDetector().findContradictions(in: [
            entry("a/CLAUDE.md", 1, "Use tabs for indentation.", repo: "a"),
            entry("b/CLAUDE.md", 1, "Use spaces for indentation.", repo: "b"),
        ])
        #expect(found.contains { $0.topicID == "indentation" })
    }

    @Test func bareMentionsAndSameRepoAreIgnored() {
        let det = ContradictionDetector()
        #expect(det.findContradictions(in: [
            entry("a/CLAUDE.md", 1, "Tests run with `npm run test`.", repo: "a"),
            entry("b/CLAUDE.md", 1, "Install with pnpm install.", repo: "b"),
        ]).isEmpty)
        #expect(det.findContradictions(in: [
            entry("a/CLAUDE.md", 1, "Always use pnpm.", repo: "a"),
            entry("a/AGENTS.md", 1, "Always use npm.", repo: "a"),
        ]).isEmpty)
    }

    @Test func topicTableIsData() throws {
        let json = #"[{"id":"db","title":"Database","options":[{"name":"postgres","aliases":["postgres"]},{"name":"mysql","aliases":["mysql"]}]}]"#
        let topics = try ContradictionTopic.decode(json: Data(json.utf8))
        let found = ContradictionDetector(topics: topics).findContradictions(in: [
            entry("a/CLAUDE.md", 1, "Always use postgres.", repo: "a"),
            entry("b/CLAUDE.md", 1, "Always use mysql.", repo: "b"),
        ])
        #expect(found.count == 1)
        #expect(found[0].topicID == "db")
    }
}

func entry(_ path: String, _ line: Int, _ text: String, repo: String? = nil) -> RuleEntry {
    RuleEntry(
        filePath: path, repoRoot: repo ?? (path as NSString).deletingLastPathComponent,
        kind: .claudeMd, line: line, text: text)
}
