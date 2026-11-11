import Foundation
@testable import MusterCore

/// A throwaway directory tree for rule scanning tests. Tests write files here; production code never does (R10).
final class TempTree {
    let root: String

    init() throws {
        let base = NSTemporaryDirectory() + "muster-rules-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> String {
        let p = path(relative)
        try FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    /// Creates `<name>/.git` so the folder counts as a repo root.
    @discardableResult
    func makeRepo(_ name: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path("\(name)/.git"), withIntermediateDirectories: true)
        return path(name)
    }

    func setModificationDate(_ date: Date, of relative: String) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
    }
}

struct FakeCommands: CommandLookup {
    var available: Set<String>
    func isAvailable(_ name: String) -> Bool { available.contains(name) }
}

func makeScanner(_ tree: TempTree, commands: Set<String> = ["git", "make"]) -> RuleScanner {
    RuleScanner(
        config: RuleScannerConfig(root: tree.root),
        refChecker: RefChecker(commands: FakeCommands(available: commands)))
}
