import MusterCore
import SwiftUI

/// 「指令」页：写一次，所有开启的 agent 在每次对话前都读到。
struct InstructionsView: View {
    @ObservedObject var model: InstructionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Shared instructions"))
            Card {
                HStack(spacing: T.s2) {
                    setMenu
                    Spacer(minLength: T.s2)
                    Button(model.isDirty ? L10n.t("Save") : L10n.t("Saved")) { model.saveNow() }
                        .buttonStyle(PillButtonStyle(kind: model.isDirty ? .primary : .secondary))
                        .disabled(!model.isDirty)
                }
                .padding(.horizontal, T.s3)
                .frame(height: T.rowDouble)
                // 浮层要盖住下面的编辑器
                .zIndex(1)

                Hairline()
                if let editor = model.editor { nameEditor(editor) }
                if model.confirmingDelete { deleteConfirm }
                TextEditor(text: $model.draft)
                    .font(T.mono)
                    .foregroundStyle(T.fg2)
                    .scrollContentBackground(.hidden)
                    .frame(height: 128)
                    .padding(.horizontal, T.s2)
                    .padding(.top, T.s1)
                Hairline()
                Text(L10n.t("Only the text between the two marker lines is written; the rest of each file stays yours."))
                    .font(T.micro)
                    .foregroundStyle(T.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, T.s3)
                    .padding(.vertical, T.s1)
            }
            .zIndex(1)

            HStack(spacing: T.s2) {
                SectionTitle(text: "AGENT", count: model.targets.count)
                if model.targets.contains(where: { model.enabled($0.id) && model.isPending($0.id) }) {
                    Button(L10n.t("Write to the enabled agents")) { model.writeAll() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .padding(.trailing, T.s3)
                        .padding(.top, T.s2)
                }
            }
            .frame(height: T.rowCompact)

            if model.targets.isEmpty {
                EmptyState(
                    title: L10n.t("No agents found"),
                    message: L10n.t("Agents that keep a user-level instructions file show up here"))
            } else {
                Card {
                    ForEach(Array(model.targets.enumerated()), id: \.element.id) { index, target in
                        AgentRow(model: model, target: target)
                        if index < model.targets.count - 1 {
                            Hairline().padding(.leading, T.s3 + 18 + T.s2)
                        }
                    }
                }
            }

            if let notice = model.notice {
                Text(notice).font(T.micro).foregroundStyle(T.muted).padding(.horizontal, T.s3)
            }
            if let error = model.errorMessage {
                Text(error).font(T.micro).foregroundStyle(T.red).padding(.horizontal, T.s3)
            }
        }
        .onAppear { model.loadIfNeeded() }
    }

    // MARK: 套

    private var setMenu: some View {
        InlineSelect(
            items: model.sets.map(\.id),
            label: { id in
                guard let set = model.sets.first(where: { $0.id == id }) else { return model.activeSetName }
                return name(of: set)
            },
            alignment: .leading,
            selection: Binding(
                get: { model.activeSetID },
                set: { model.selectSet($0) })
        ) {
            Hairline().padding(.vertical, T.s1)
            setAction(L10n.t("New set…")) {
                model.setName = ""
                model.editor = .create
                model.confirmingDelete = false
            }
            if !model.isDefaultSet {
                setAction(L10n.t("Rename this set…")) {
                    model.setName = model.activeSetName
                    model.editor = .rename
                    model.confirmingDelete = false
                }
                setAction(L10n.t("Delete this set…")) {
                    model.editor = nil
                    model.confirmingDelete = true
                }
            }
        }
    }

    private func nameEditor(_ editor: InstructionsModel.SetEditor) -> some View {
        HStack(spacing: T.s2) {
            TextField(L10n.t("Name"), text: $model.setName)
                .textFieldStyle(.plain)
                .font(T.body)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: T.rInner, style: .continuous).fill(T.card2))
                .overlay(RoundedRectangle(cornerRadius: T.rInner, style: .continuous)
                    .strokeBorder(T.accent, lineWidth: 1))
                .onSubmit { commit(editor) }
            Button(L10n.t("Save")) { commit(editor) }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(model.setName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(L10n.t("Cancel")) {
                model.editor = nil
                model.setName = ""
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .padding(.horizontal, T.s3)
        .padding(.vertical, T.s2)
    }

    private func commit(_ editor: InstructionsModel.SetEditor) {
        switch editor {
        case .create: model.createSet()
        case .rename: model.renameSet()
        }
    }

    private var deleteConfirm: some View {
        HStack(spacing: T.s2) {
            Text(L10n.t("Delete “%@” and its text?", model.activeSetName))
                .font(T.small)
                .foregroundStyle(T.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: T.s2)
            Button(L10n.t("Delete")) { model.deleteActiveSet() }
                .buttonStyle(PillButtonStyle(kind: .primary))
            Button(L10n.t("Cancel")) {
                model.confirmingDelete = false
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .padding(.horizontal, T.s3)
        .padding(.vertical, T.s2)
    }

    private func name(of set: InstructionSet) -> String {
        set.id == InstructionSet.defaultID ? L10n.t("Default") : set.name
    }

    private func setAction(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(T.small).foregroundStyle(T.fg2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, T.s2)
            .frame(height: 24)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
    }
}

private struct AgentRow: View {
    @ObservedObject var model: InstructionsModel
    let target: InstructionTarget
    @State private var previewMode: PreviewMode = .diff

    private enum PreviewMode: String, CaseIterable, Hashable {
        case diff, full
    }

    private var plan: InstructionPlan? { model.plan(target.id) }
    private var on: Bool { model.enabled(target.id) }
    private var expanded: Bool { model.expanded.contains(target.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: T.s2) {
                AgentLogo(agentID: target.id, mark: mark)
                VStack(alignment: .leading, spacing: 0) {
                    Text(target.name).font(T.body).foregroundStyle(T.fg).lineLimit(1)
                    Text(target.abbreviatedPath)
                        .font(T.monoMicro)
                        .foregroundStyle(T.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(target.redirectedFrom.map {
                            L10n.t("This file overrides %@", ($0 as NSString).abbreviatingWithTildeInPath)
                        } ?? target.path)
                }
                Spacer(minLength: T.s2)
                Text(statusLabel).font(T.micro).foregroundStyle(statusColor).lineLimit(1)
                Button {
                    if expanded { model.expanded.remove(target.id) } else { model.expanded.insert(target.id) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(T.glyph)
                        .foregroundStyle(T.faint)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("Show the preview"))
                MiniSwitch(isOn: Binding(get: { on }, set: { model.toggle(target, on: $0) }))
                    .disabled(!target.installed)
                    .opacity(target.installed ? 1 : 0.4)
            }
            .padding(.horizontal, T.s3)
            .frame(height: 42)

            if expanded { preview }
        }
        .hoverHighlight()
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            Text(L10n.t("Own %d lines stay untouched", plan?.ownLineCount ?? 0))
                .font(T.micro)
                .foregroundStyle(T.muted)
            if target.redirectedFrom != nil {
                Text(L10n.t("AGENTS.override.md wins over AGENTS.md, so this is the file that takes effect."))
                    .font(T.micro)
                    .foregroundStyle(T.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let plan {
                CodeBlock(lines: previewMode == .diff ? diffLines(plan) : fullFileLines(plan))
            }
            if let plan {
                HStack(spacing: T.s2) {
                    SegmentedControl(items: PreviewMode.allCases, selection: $previewMode) { mode in
                        mode == .diff ? L10n.t("Show changes") : L10n.t("Show the whole file")
                    }
                    .frame(width: 168)
                    Text(detail(plan)).font(T.micro).foregroundStyle(T.faint).lineLimit(1)
                    Spacer(minLength: T.s2)
                    Button(L10n.t("Write")) { model.write(target) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .disabled(!target.installed)
                }
            }
            backupRow
        }
        .padding(.horizontal, T.s3)
        .padding(.bottom, T.s2)
    }

    @ViewBuilder private var backupRow: some View {
        if let latest = model.backups(for: target).first, latest.createdAt != .distantPast {
            HStack(spacing: T.s2) {
                Text(L10n.t("Backup from %@", latest.createdAt.formatted(date: .abbreviated, time: .shortened)))
                    .font(T.micro)
                    .foregroundStyle(T.faint)
                    .lineLimit(1)
                Spacer(minLength: T.s2)
                Button(L10n.t("Restore")) { model.restore(latest, to: target) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .help(L10n.t("The current file is backed up first, so this can be undone too."))
            }
        }
    }

    private func diffLines(_ plan: InstructionPlan) -> [DetailLine] {
        var lines: [DetailLine] = []
        if let existing = plan.existingBlock, !existing.isEmpty {
            lines += existing.split(separator: "\n", omittingEmptySubsequences: false)
                .map { DetailLine(kind: .remove, text: "- " + $0) }
        }
        if !plan.newBlock.isEmpty {
            lines += plan.newBlock.split(separator: "\n", omittingEmptySubsequences: false)
                .map { DetailLine(kind: .add, text: "+ " + $0) }
        }
        return Array(lines.prefix(40))
    }

    /// 写入后整份文件的样子，用来确认段落在文件里的位置。
    private func fullFileLines(_ plan: InstructionPlan) -> [DetailLine] {
        let text = plan.resultingFile.isEmpty ? plan.newBlock : plan.resultingFile
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(60)
            .map { DetailLine(kind: .plain, text: String($0)) }
    }

    private func detail(_ plan: InstructionPlan) -> String {
        switch plan.action {
        case .create: return L10n.t("Adds the block")
        case .update: return L10n.t("Replaces the block")
        case .remove: return L10n.t("Removes the block")
        case .unchanged: return L10n.t("Nothing to write")
        case .skipped(let reason): return reason
        }
    }

    /// 没有 logo 文件时的单字：Pi 用「π」，其余取名字首字
    private var mark: String {
        target.id == "pi" ? "π" : String(target.name.prefix(1))
    }

    private var statusLabel: String {
        guard target.installed else { return L10n.t("Not installed") }
        guard let plan else { return "" }
        switch plan.action {
        case .unchanged:
            return on ? L10n.t("Up to date") : ""
        case .create, .update, .remove:
            return L10n.t("Pending")
        case .skipped("edited in the file"):
            return L10n.t("Edited in file")
        case .skipped("empty"):
            return L10n.t("Empty shared text")
        case .skipped:
            return ""
        }
    }

    private var statusColor: Color {
        guard target.installed, let plan else { return T.faint }
        switch plan.action {
        case .create, .update, .remove: return T.amber
        case .skipped("edited in the file"): return T.amber
        case .unchanged: return T.muted
        case .skipped: return T.faint
        }
    }
}
