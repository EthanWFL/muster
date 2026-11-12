import Foundation
import Testing
@testable import MusterCore

@Suite struct InstructionBlockTests {
    @Test func writesIntoAnEmptyFile() {
        let file = InstructionBlock.withBlock("", "共享规则一行")
        #expect(file == InstructionBlock.begin + "\n共享规则一行\n" + InstructionBlock.end + "\n")
    }

    @Test func keepsTheUsersOwnTextAndAppendsAfterIt() {
        let under = "# 我自己的规则\n\n- 先理解，再改动\n"
        let file = InstructionBlock.withBlock(under, "共享规则")
        #expect(file.hasPrefix("# 我自己的规则\n\n- 先理解，再改动\n\n"))
        #expect(file.contains(InstructionBlock.begin))
        #expect(InstructionBlock.own(file) == under.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(InstructionBlock.ownLineCount(file) == 2)
    }

    @Test func replacingTheBlockLeavesTheRestAlone() {
        let once = InstructionBlock.withBlock("我自己的内容\n", "第一版")
        let twice = InstructionBlock.withBlock(once, "第二版")
        #expect(twice.contains("第二版"))
        #expect(!twice.contains("第一版"))
        #expect(InstructionBlock.own(twice) == "我自己的内容")
    }

    @Test func removingTheBlockLeavesOwnText() {
        let file = InstructionBlock.withBlock("我自己的内容\n", "共享规则")
        let bare = InstructionBlock.withBlock(file, "")
        #expect(bare == "我自己的内容\n")
        #expect(InstructionBlock.split(bare) == nil)
    }

    @Test func blockInsertedBeforeOwnTextIsKeptIntact() {
        // 用户自己的内容在这段之后的情形（例如手写把段挪到了开头）
        let file = InstructionBlock.begin + "\n共享\n" + InstructionBlock.end + "\n\n我自己的内容\n"
        #expect(InstructionBlock.own(file) == "我自己的内容")
        #expect(InstructionBlock.withBlock(file, "新共享").hasSuffix("我自己的内容\n"))
    }

    @Test func crlfIsNormalised() {
        let file = InstructionBlock.withBlock("自己的\r\n", "共享")
        #expect(!file.contains("\r"))
    }

    @Test func hashDetectsAHandEdit() {
        let written = InstructionBlock.withBlock("", "共享规则")
        let edited = InstructionBlock.withBlock("", "共享规则，我改了一个字")
        #expect(InstructionBlock.hash(InstructionBlock.split(written)!.block) != InstructionBlock.hash(InstructionBlock.split(edited)!.block))
    }
}

@Suite struct InstructionSyncTests {
    private func makeTarget(_ tree: TempTree, _ id: String = "claude", _ content: String? = nil) throws -> InstructionTarget {
        let path = tree.path("agent/\(id).md")
        if let content {
            try tree.write("agent/\(id).md", content)
        } else {
            try FileManager.default.createDirectory(
                atPath: tree.path("agent"), withIntermediateDirectories: true)
        }
        return InstructionTarget(id: id, name: id, path: path, installed: true)
    }

    private func sync(_ tree: TempTree) -> InstructionSync {
        InstructionSync(paths: InstructionPaths(support: tree.path("support")))
    }

    @Test func planCreatesAFileWhenThereIsNoBlockYet() throws {
        let t = try TempTree()
        let target = try makeTarget(t, "claude", "我自己的内容\n")
        let plan = sync(t).plan(for: target, sharedText: "共享规则", state: InstructionSyncState())

        #expect(plan.action == .create)
        #expect(plan.ownLineCount == 1)
        #expect(plan.resultingFile.contains("共享规则"))
        #expect(plan.resultingFile.contains("我自己的内容"))
    }

    @Test func applyWritesTheFileAndKeepsABackup() throws {
        let t = try TempTree()
        let target = try makeTarget(t, "claude", "我自己的内容\n")
        let sync = sync(t)
        let plan = sync.plan(for: target, sharedText: "共享规则", state: InstructionSyncState())

        let done = try sync.apply(plan)
        let written = try String(contentsOfFile: target.path, encoding: .utf8)
        #expect(written == plan.resultingFile)
        #expect(InstructionBlock.own(written) == "我自己的内容")

        let backup = try #require(done.backupPath)
        #expect(try String(contentsOfFile: backup, encoding: .utf8) == "我自己的内容\n")
    }

    @Test func sameTextIsNoWrite() throws {
        let t = try TempTree()
        let target = try makeTarget(t, "claude", "")
        let sync = sync(t)
        var state = InstructionSyncState()
        let first = sync.plan(for: target, sharedText: "共享规则", state: state)
        try sync.apply(first)
        state.writtenHash["claude"] = InstructionBlock.hash("共享规则")

        #expect(sync.plan(for: target, sharedText: "共享规则", state: state).action == .unchanged)
    }

    @Test func handEditedBlockIsKeptWhenTheSharedTextIsUnchanged() throws {
        let t = try TempTree()
        let target = try makeTarget(t, "claude", "")
        let sync = sync(t)
        // 先按「共享规则」写过一次
        let first = sync.plan(for: target, sharedText: "共享规则", state: InstructionSyncState())
        try sync.apply(first)
        var state = InstructionSyncState()
        state.writtenHash["claude"] = InstructionBlock.hash("共享规则")

        // 用户在文件里手改了这个段
        let edited = InstructionBlock.withBlock("", "共享规则（我手改的）")
        try edited.write(toFile: target.path, atomically: true, encoding: .utf8)

        let plan = sync.plan(for: target, sharedText: "共享规则", state: state)
        #expect(plan.action == .skipped("edited in the file"))
        #expect(try String(contentsOfFile: target.path, encoding: .utf8) == edited)
    }

    @Test func newSharedTextOverwritesAHandEditedBlock() throws {
        let t = try TempTree()
        let target = try makeTarget(t, "claude", "")
        let sync = sync(t)
        var state = InstructionSyncState()
        state.writtenHash["claude"] = InstructionBlock.hash("共享规则")
        try InstructionBlock.withBlock("", "共享规则（我手改的）")
            .write(toFile: target.path, atomically: true, encoding: .utf8)

        let plan = sync.plan(for: target, sharedText: "共享规则 v2", state: state)
        #expect(plan.action == .update)
        #expect(plan.resultingFile.contains("共享规则 v2"))
    }

    @Test func emptySharedTextNeverRemovesABlock() throws {
        let t = try TempTree()
        let target = try makeTarget(t, "claude", "")
        let sync = sync(t)
        let file = InstructionBlock.withBlock("我自己的内容\n", "共享规则")
        try file.write(toFile: target.path, atomically: true, encoding: .utf8)

        let plan = sync.plan(for: target, sharedText: "   ", state: InstructionSyncState())
        #expect(plan.action == .skipped("empty"))
        #expect(try String(contentsOfFile: target.path, encoding: .utf8) == file)
    }

    @Test func removalTakesOnlyTheBlock() throws {
        let t = try TempTree()
        let target = try makeTarget(t, "claude", "")
        let sync = sync(t)
        let file = InstructionBlock.withBlock("我自己的内容\n", "共享规则")
        try file.write(toFile: target.path, atomically: true, encoding: .utf8)

        let plan = sync.planRemoval(for: target)
        #expect(plan.action == .remove)
        try sync.apply(plan)
        let after = try String(contentsOfFile: target.path, encoding: .utf8)
        #expect(after == "我自己的内容\n")
    }

    @Test func missingAgentIsSkipped() throws {
        let t = try TempTree()
        let target = InstructionTarget(
            id: "ghost", name: "Ghost", path: t.path("nowhere/AGENTS.md"), installed: false)
        let plan = sync(t).plan(for: target, sharedText: "共享规则", state: InstructionSyncState())
        #expect(plan.action == .skipped("not installed"))
    }

    @Test func targetsAreDetectedFromTheHomeDirectory() throws {
        let t = try TempTree()
        try t.write(".claude/CLAUDE.md", "")
        try t.write(".codex/AGENTS.md", "")
        let found = InstructionTargets.detect(
            home: t.root, environment: [:],
            exists: { FileManager.default.fileExists(atPath: $0) })

        #expect(found.first { $0.id == "claude" }?.installed == true)
        #expect(found.first { $0.id == "claude" }?.path == t.path(".claude/CLAUDE.md"))
        #expect(found.first { $0.id == "codex" }?.installed == true)
        #expect(found.first { $0.id == "gemini" }?.installed == false)
    }

    @Test func environmentOverridesTheDefaultDirectories() {
        let found = InstructionTargets.detect(
            home: "/Users/tester",
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/custom-claude"],
            exists: { _ in false })
        #expect(found.first { $0.id == "claude" }?.path == "/tmp/custom-claude/CLAUDE.md")
    }
}

@Suite struct InstructionSetTests {
    @Test func oldStateFilesStillDecodeTheirFlagsAndHashes() throws {
        let json = #"{"enabled":{"claude":true},"writtenHash":{"claude":"ab12"}}"#
        let state = try JSONDecoder().decode(InstructionSyncState.self, from: Data(json.utf8))
        #expect(state.enabled["claude"] == true)
        #expect(state.writtenHash["claude"] == "ab12")
        #expect(state.activeSet == InstructionSet.defaultID)
        #expect(state.sets.isEmpty)
    }

    @Test func everySetHasItsOwnFile() throws {
        let t = try TempTree()
        let sync = InstructionSync(paths: InstructionPaths(support: t.path("support")))
        let set = try sync.createSet(named: "工作规则")

        try sync.saveText("只属于这一套", setID: set.id)
        try sync.saveText("默认那套", setID: InstructionSet.defaultID)

        #expect(sync.text(set.id) == "只属于这一套")
        #expect(sync.text(InstructionSet.defaultID) == "默认那套")
        #expect(set.id != InstructionSet.defaultID)
    }

    @Test func unknownActiveSetFallsBackToDefault() {
        let state = InstructionSyncState(activeSet: "gone")
        #expect(state.resolvedActiveSet == InstructionSet.defaultID)
        #expect(state.allSets.map(\.id) == [InstructionSet.defaultID])
    }

    @Test func overrideFileWinsOverAgentsMd() throws {
        let t = try TempTree()
        try t.write(".codex/AGENTS.md", "")
        try t.write(".codex/AGENTS.override.md", "")
        let found = InstructionTargets.detect(
            home: t.root, environment: [:],
            exists: { FileManager.default.fileExists(atPath: $0) })

        let codex = try #require(found.first { $0.id == "codex" })
        #expect(codex.path == t.path(".codex/AGENTS.override.md"))
        #expect(codex.redirectedFrom == t.path(".codex/AGENTS.md"))
    }
}

@Suite struct InstructionBackupTests {
    private func write(_ sync: InstructionSync, _ target: InstructionTarget, _ text: String) throws {
        try FileManager.default.createDirectory(
            atPath: (target.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: target.path, atomically: true, encoding: .utf8)
    }

    @Test func backupsAreListedNewestFirstWithTheirOriginalPath() throws {
        let t = try TempTree()
        let target = InstructionTarget(
            id: "claude", name: "Claude", path: t.path("agent/CLAUDE.md"), installed: true)
        let sync = InstructionSync(paths: InstructionPaths(support: t.path("support")))
        try write(sync, target, "第一版\n")
        try sync.apply(sync.plan(for: target, sharedText: "A", state: InstructionSyncState()))
        try write(sync, target, InstructionBlock.withBlock("第一版\n", "B"))
        try sync.apply(sync.plan(for: target, sharedText: "C", state: InstructionSyncState()))

        let found = sync.backups(for: "claude")
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.originalPath == target.path })
    }

    @Test func restoringPutTheOldFileBackAndKeepsANewBackup() throws {
        let t = try TempTree()
        let target = InstructionTarget(
            id: "claude", name: "Claude", path: t.path("agent/CLAUDE.md"), installed: true)
        let sync = InstructionSync(paths: InstructionPaths(support: t.path("support")))
        try write(sync, target, "原始内容\n")
        try sync.apply(sync.plan(for: target, sharedText: "共享", state: InstructionSyncState()))

        let backup = try #require(sync.backups(for: "claude").first)
        try sync.restore(backup, to: target)

        #expect(try String(contentsOfFile: target.path, encoding: .utf8) == "原始内容\n")
        // 恢复前又把「写过共享」的那版备份了一次，所以现在有两条
        #expect(sync.backups(for: "claude").count == 2)
    }

    @Test func deletingASetRemovesItsFileOnly() throws {
        let t = try TempTree()
        let sync = InstructionSync(paths: InstructionPaths(support: t.path("support")))
        let set = try sync.createSet(named: "临时")
        try sync.saveText("这一套的文本", setID: set.id)
        try sync.saveText("默认文本", setID: InstructionSet.defaultID)

        try sync.deleteSet(set.id)

        #expect(sync.text(set.id).isEmpty)
        #expect(sync.text(InstructionSet.defaultID) == "默认文本")
    }
}
