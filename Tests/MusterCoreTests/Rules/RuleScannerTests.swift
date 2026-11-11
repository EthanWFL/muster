import Foundation
import Testing
@testable import MusterCore

@Suite struct RuleScannerTests {
    @Test func findsTheFourFileKindsAndSkipsExcludedDirectories() async throws {
        let t = try TempTree()
        try t.makeRepo("a")
        try t.write("a/CLAUDE.md", "- Keep functions small and focused.\n")
        try t.write("a/AGENTS.md", "- Write tests for every bug fix you make.\n")
        try t.write("a/.cursorrules", "Prefer composition over inheritance in all modules.\n")
        try t.write("a/.github/copilot-instructions.md", "- Document public API with doc comments.\n")
        try t.write("a/node_modules/pkg/CLAUDE.md", "- Should never be scanned.\n")
        try t.write("a/.build/AGENTS.md", "- Should never be scanned either.\n")
        try t.write("a/docs/copilot-instructions.md", "- Only counts inside .github.\n")

        let report = try await makeScanner(t).scan()
        let kinds = Set(report.files.map(\.kind))
        #expect(kinds == Set(RuleFileKind.allCases))
        #expect(report.files.count == 4)
        #expect(report.files.allSatisfy { $0.repoRoot == t.path("a") })
    }

    @Test func splitsEntriesWithLineNumbers() async throws {
        let t = try TempTree()
        try t.makeRepo("a")
        try t.write("a/CLAUDE.md", "# Title\n\n- first rule here\n- second rule here\n\nA paragraph rule\nspanning two lines.\n")
        let report = try await makeScanner(t).scan()
        let lines = report.files[0].entries.map(\.line)
        #expect(lines == [3, 4, 6])
    }

    @Test func incrementalRescanSkipsUnchangedFiles() async throws {
        let t = try TempTree()
        try t.makeRepo("a")
        try t.makeRepo("b")
        try t.write("a/CLAUDE.md", "- Rule number one for repo a.\n")
        try t.write("b/CLAUDE.md", "- Rule number one for repo b.\n")
        let scanner = makeScanner(t)

        let first = try await scanner.scan()
        #expect(first.stats.filesParsed == 2)
        #expect(first.stats.filesFromCache == 0)

        let second = try await scanner.scan()
        #expect(second.stats.filesParsed == 0)
        #expect(second.stats.filesFromCache == 2)
        #expect(second.stats.entryCount == first.stats.entryCount)

        try t.write("b/CLAUDE.md", "- Rule number one for repo b.\n- A brand new second rule.\n")
        try t.setModificationDate(Date().addingTimeInterval(120), of: "b/CLAUDE.md")
        let third = try await scanner.scan()
        #expect(third.stats.filesParsed == 1)
        #expect(third.stats.filesFromCache == 1)
        #expect(third.stats.reparsedPaths == [t.path("b/CLAUDE.md")])
        #expect(third.stats.entryCount == 3)
    }

    @Test func removedFilesLeaveTheCache() async throws {
        let t = try TempTree()
        try t.makeRepo("a")
        try t.write("a/CLAUDE.md", "- Some rule text goes here.\n")
        let scanner = makeScanner(t)
        _ = try await scanner.scan()
        #expect(scanner.cachedFileCount == 1)
        try FileManager.default.removeItem(atPath: t.path("a/CLAUDE.md"))
        let report = try await scanner.scan()
        #expect(report.files.isEmpty)
        #expect(scanner.cachedFileCount == 0)
    }

    @Test func reportsProgressAndNeverWritesRuleFiles() async throws {
        let t = try TempTree()
        try t.makeRepo("a")
        let file = try t.write("a/CLAUDE.md", "- Some rule text goes here.\n")
        let before = try Data(contentsOf: URL(fileURLWithPath: file))
        let attrs = try FileManager.default.attributesOfItem(atPath: file)

        let phases = PhaseLog()
        _ = try await makeScanner(t).scan(progress: { phases.add($0.phase) })

        #expect(phases.values.contains(.parsing))
        #expect(phases.values.last == .done)
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date
                == attrs[.modificationDate] as? Date)
    }

    @Test func tenReposScanQuickly() async throws {
        let t = try TempTree()
        for i in 0..<10 {
            try t.makeRepo("repo\(i)")
            var text = ""
            for j in 0..<60 { text += "- Rule \(j) of repo \(i): handle topic\(j * 7 + i) carefully with `Sources/App\(j).swift`.\n" }
            try t.write("repo\(i)/CLAUDE.md", text)
            try t.write("repo\(i)/AGENTS.md", text)
        }
        let report = try await makeScanner(t).scan()
        #expect(report.files.count == 20)
        #expect(report.stats.duration < 3)
    }
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [RuleScanProgress.Phase] = []
    func add(_ p: RuleScanProgress.Phase) { lock.lock(); list.append(p); lock.unlock() }
    var values: [RuleScanProgress.Phase] { lock.lock(); defer { lock.unlock() }; return list }
}
