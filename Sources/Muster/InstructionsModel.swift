import Foundation
import MusterCore
import SwiftUI

/// 「指令」页：一份共享指令，写进各 agent 的用户级指令文件（只写标记之间的那段）。
@MainActor
final class InstructionsModel: ObservableObject {
    @Published private(set) var targets: [InstructionTarget] = []
    @Published private(set) var plans: [String: InstructionPlan] = [:]
    @Published private(set) var state = InstructionSyncState()
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var hasLoaded = false
    @Published private(set) var activeSetID = InstructionSet.defaultID
    @Published private(set) var savedText = ""

    /// 编辑中的文本：改完会自动存进当前这套，所以退出 App 也不丢。
    @Published var draft = "" { didSet { if draft != oldValue { scheduleSave() } } }
    @Published var expanded: Set<String> = []
    /// 新建 / 删除确认，同一时间只开一个
    @Published var creatingSet = false
    @Published var setName = ""
    @Published var confirmingDelete = false

    private let sync: InstructionSync
    private let detectTargets: () -> [InstructionTarget]
    private var saveTask: Task<Void, Never>?

    init(sync: InstructionSync = InstructionSync(),
         detectTargets: @escaping () -> [InstructionTarget] = { InstructionTargets.detect() }) {
        self.sync = sync
        self.detectTargets = detectTargets
    }

    var isDirty: Bool { draft != savedText }
    var sets: [InstructionSet] { state.allSets }
    var activeSetName: String {
        activeSetID == InstructionSet.defaultID
            ? L10n.t("Default")
            : (state.setNamed(activeSetID)?.name ?? "")
    }
    var isDefaultSet: Bool { activeSetID == InstructionSet.defaultID }

    /// 列表里那行副标题：该套第一行内容（当前那套用未落盘的草稿）
    func previewText(_ id: String) -> String {
        let text = id == activeSetID ? draft : sync.text(id)
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        // 只列本机确实装了的：没有指令文件的 agent 不给开关
        targets = detectTargets().filter(\.installed)
        state = sync.state()
        activeSetID = state.resolvedActiveSet
        savedText = sync.text(activeSetID)
        draft = savedText
        refreshPlans()
    }

    // MARK: 多套指令

    /// 只切换编辑中的草稿。查看规则不修改任何 Agent 文件。
    func selectSet(_ id: String) {
        guard id != activeSetID, state.setNamed(id) != nil else { return }
        flushPendingSave()
        activeSetID = id
        state.activeSet = id
        persistState()
        savedText = sync.text(id)
        draft = savedText
        refreshPlans()
        notice = L10n.t("Viewing %@ · agent files unchanged", activeSetName)
    }

    func createSet() {
        let name = setName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            flushPendingSave()
            let set = try sync.createSet(named: name)
            state.sets.append(set)
            state.activeSet = set.id
            persistState()
            activeSetID = set.id
            savedText = ""
            draft = ""
            creatingSet = false
            setName = ""
            refreshPlans()
            notice = L10n.t("Created %@", name)
        } catch {
            errorMessage = L10n.t("Could not save: %@", L10n.t(error.localizedDescription))
        }
    }

    /// 行内改名，失焦即调；默认那套名字固定
    func renameSet(_ id: String, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, id != InstructionSet.defaultID,
              let index = state.sets.firstIndex(where: { $0.id == id }),
              state.sets[index].name != name else { return }
        state.sets[index].name = name
        persistState()
        notice = L10n.t("Renamed to %@", name)
    }

    /// 删掉当前这套（默认那套不能删），然后回到默认。
    func deleteActiveSet() {
        guard !isDefaultSet else { return }
        let removed = activeSetName
        do {
            saveTask?.cancel()
            try sync.deleteSet(activeSetID)
            state.sets.removeAll { $0.id == activeSetID }
            state.activeSet = InstructionSet.defaultID
            persistState()
            activeSetID = InstructionSet.defaultID
            savedText = sync.text(InstructionSet.defaultID)
            draft = savedText
            confirmingDelete = false
            refreshPlans()
            notice = L10n.t("Deleted %@", removed)
        } catch {
            errorMessage = L10n.t("Could not delete %@: %@", removed, L10n.t(error.localizedDescription))
        }
    }

    // MARK: 编辑

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try sync.saveText(draft, setID: activeSetID)
            savedText = draft
            refreshPlans()
        } catch {
            errorMessage = L10n.t("Could not save: %@", L10n.t(error.localizedDescription))
        }
    }

    /// 每次改动后 1.2 秒落盘，避免边打字边写文件。
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func flushPendingSave() {
        guard isDirty else { saveTask?.cancel(); return }
        saveNow()
    }

    // MARK: 写入

    func toggle(_ target: InstructionTarget, on: Bool) {
        state.enabled[target.id] = on
        persistState()
        refreshPlans()
        expanded.insert(target.id)
        notice = L10n.t("Review the preview, then apply changes.")
    }

    func write(_ target: InstructionTarget) {
        guard !isDirty, let plan = plans[target.id] else { return }
        do {
            let done = try sync.apply(plan)
            if done.action == .create || done.action == .update {
                state.writtenHash[target.id] = InstructionBlock.hash(done.newBlock)
            }
            if done.action == .remove { state.writtenHash[target.id] = nil }
            persistState()
            errorMessage = nil
            notice = describe(done)
            refreshPlans()
        } catch {
            errorMessage = L10n.t("Could not write %@: %@", target.name, L10n.t(error.localizedDescription))
            refreshPlans()
        }
    }

    func writeAll() {
        guard !isDirty else { return }
        let written = applyPending()
        if written == 0, errorMessage == nil { notice = L10n.t("Nothing to write") }
    }

    /// 应用预览中的写入或移除；部分失败会点名，已写成功的保留。
    @discardableResult
    private func applyPending() -> Int {
        var written = 0
        var failed: [String] = []
        for target in targets where isPending(target.id) {
            do {
                guard let plan = plans[target.id] else { continue }
                let done = try sync.apply(plan)
                if done.action == .create || done.action == .update {
                    state.writtenHash[target.id] = InstructionBlock.hash(done.newBlock)
                    written += 1
                }
                if done.action == .remove {
                    state.writtenHash[target.id] = nil
                    written += 1
                }
            } catch {
                failed.append(target.name)
            }
        }
        persistState()
        if !failed.isEmpty {
            errorMessage = L10n.t("Could not write: %@", failed.joined(separator: ", "))
        } else {
            errorMessage = nil
            if written > 0 { notice = L10n.t("Wrote %d agents", written) }
        }
        refreshPlans()
        return written
    }

    // MARK: 备份

    func backups(for target: InstructionTarget) -> [InstructionBackup] {
        sync.backups(for: target.id, limit: 3)
    }

    /// 恢复某次备份前，当前文件也会先备份一次，所以这一步同样可撤销。
    func restore(_ backup: InstructionBackup, to target: InstructionTarget) {
        do {
            try sync.restore(backup, to: target)
            if let file = try? String(contentsOfFile: target.path, encoding: .utf8),
               let block = InstructionBlock.split(file)?.block, !block.isEmpty {
                state.writtenHash[target.id] = InstructionBlock.hash(block)
            } else {
                state.writtenHash[target.id] = nil
            }
            persistState()
            notice = L10n.t("Restored %@", target.name)
            refreshPlans()
        } catch {
            errorMessage = L10n.t("Could not restore %@: %@", target.name, L10n.t(error.localizedDescription))
        }
    }

    // MARK: 状态

    func enabled(_ id: String) -> Bool { state.enabled[id] ?? false }

    func plan(_ id: String) -> InstructionPlan? { plans[id] }

    func isPending(_ id: String) -> Bool {
        guard let plan = plans[id] else { return false }
        switch plan.action {
        case .create, .update, .remove: return true
        case .unchanged, .skipped: return false
        }
    }

    private func refreshPlans() {
        var next: [String: InstructionPlan] = [:]
        for target in targets {
            next[target.id] = enabled(target.id)
                ? sync.plan(for: target, sharedText: draft, state: state)
                : sync.planRemoval(for: target)
        }
        plans = next
    }

    private func persistState() {
        do { try sync.save(state) } catch {
            errorMessage = L10n.t("Could not save: %@", L10n.t(error.localizedDescription))
        }
    }

    private func describe(_ plan: InstructionPlan) -> String {
        switch plan.action {
        case .create: return L10n.t("%@ synced", plan.target.name)
        case .update: return L10n.t("%@ updated", plan.target.name)
        case .remove: return L10n.t("%@ cleared", plan.target.name)
        case .unchanged: return L10n.t("%@ is up to date", plan.target.name)
        case .skipped(let reason): return L10n.t("%@ skipped: %@", plan.target.name, reason)
        }
    }
}
