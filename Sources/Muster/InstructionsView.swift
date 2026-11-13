import MusterCore
import SwiftUI

/// 「指令」页：写一次，所有开启的 agent 在每次对话前都读到。
struct InstructionsView: View {
    @ObservedObject var model: InstructionsModel
    @Environment(\.panelPresentation) private var presentation
    @State private var openSetID: String?
    @State private var editingName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Shared rules"))
            Card {
                ForEach(Array(model.sets.enumerated()), id: \.element.id) { index, set in
                    setSection(set)
                    if index < model.sets.count - 1 {
                        Hairline()
                    }
                }
                if model.creatingSet {
                    Hairline()
                    createRow
                }
                if model.confirmingDelete {
                    Hairline()
                    deleteConfirm
                }
                Hairline()
                HStack(spacing: T.s2) {
                    newSetButton
                    Spacer(minLength: T.s2)
                    if model.isDirty {
                        HStack(spacing: 5) {
                            Circle().fill(T.amber).frame(width: 5, height: 5)
                            Text(L10n.t("Unsaved changes")).font(T.micro).foregroundStyle(T.muted)
                        }
                    } else {
                        Text("Markdown").font(T.micro).foregroundStyle(T.faint)
                    }
                    Button { model.saveNow() } label: {
                        ShortcutLabel(title: model.isDirty ? L10n.t("Save draft") : L10n.t("Draft saved"), glyph: "⌘S")
                    }
                        .buttonStyle(PillButtonStyle(kind: model.isDirty ? .primary : .secondary))
                        .disabled(!model.isDirty)
                        .keyboardShortcut("s", modifiers: .command)
                }
                .padding(.horizontal, T.s3)
                .frame(height: T.rowDouble)
            }

            Text(L10n.t("Saving keeps a local draft. Apply writes the preview; turning a target off previews removal."))
                .font(T.small).foregroundStyle(T.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, T.s3)

            SectionTitle(text: L10n.t("Agents"), count: model.targets.count)
                .overlay(alignment: .trailing) {
                    if model.targets.contains(where: { model.isPending($0.id) }) {
                        Button(L10n.t("Review changes")) {
                            model.expanded.formUnion(model.targets.filter { model.isPending($0.id) }.map(\.id))
                        }
                            .buttonStyle(PillButtonStyle(kind: .primary))
                            .padding(.trailing, T.s3)
                    }
                }

            if model.targets.isEmpty {
                EmptyState(
                    title: L10n.t("No agents found"),
                    message: L10n.t("Agents that keep a user-level rules file show up here"))
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

            if model.targets.contains(where: { model.isPending($0.id) }) {
                HStack {
                    Text(L10n.t("%d agents pending", model.targets.filter { model.isPending($0.id) }.count))
                        .font(T.small).foregroundStyle(T.muted)
                    Spacer()
                    Button(L10n.t("Apply changes")) { model.writeAll() }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .disabled(model.isDirty)
                }
                .padding(.horizontal, T.s3)
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

    /// 默认全部收起；展开仅选择编辑中的草稿。
    private func setSection(_ set: InstructionSet) -> some View {
        let open = openSetID == set.id
        return VStack(spacing: 0) {
            setHeader(set, active: set.id == model.activeSetID, open: open)
            if open {
                if !isDefault(set) { renameRow }
                TextEditor(text: $model.draft)
                    .font(T.mono)
                    .foregroundStyle(T.fg2)
                    .scrollContentBackground(.hidden)
                    .frame(height: editorHeight)
                    .padding(.horizontal, 6)
                    .padding(.vertical, T.s1)
                    .background(RoundedRectangle(cornerRadius: T.rInner, style: .continuous).fill(T.card2))
                    .overlay(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text(L10n.t("Write the rules every agent should read, in Markdown…"))
                                .font(T.mono).foregroundStyle(T.faint)
                                .padding(.horizontal, 11).padding(.vertical, 9)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: T.rInner, style: .continuous)
                        .strokeBorder(T.line, lineWidth: 0.5))
                    .padding(.horizontal, T.s3)
                    .padding(.top, T.s1)
                Text(L10n.t("Only the text between the two marker lines is written; the rest of each file stays yours."))
                    .font(T.micro)
                    .foregroundStyle(T.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, T.s3)
                    .padding(.vertical, T.s1)
            }
        }
    }

    private func setHeader(_ set: InstructionSet, active: Bool, open: Bool) -> some View {
        let preview = model.previewText(set.id)
        return HStack(spacing: T.s2) {
            Button { toggle(set) } label: {
                HStack(spacing: T.s2) {
                    Image(systemName: active ? "largecircle.fill.circle" : "circle")
                        .font(T.glyph)
                        .foregroundStyle(active ? T.accent : T.faint)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name(of: set))
                            .font(T.body)
                            .foregroundStyle(active ? T.fg : T.fg2)
                            .lineLimit(1)
                        if !preview.isEmpty {
                            Text(preview)
                                .font(T.micro)
                                .foregroundStyle(T.faint)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: T.s2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(InteractivePlainButtonStyle())
            if open && !isDefault(set) { setMenuButton }
            Button { toggle(set) } label: {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(T.glyph)
                    .foregroundStyle(T.faint)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(InteractivePlainButtonStyle())
            .accessibilityLabel(open ? L10n.t("Collapse") : L10n.t("Expand"))
        }
        .padding(.horizontal, T.s3)
        .padding(.vertical, 6)
        .hoverHighlight()
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    /// 展开只切换草稿，不写入 Agent。
    private func toggle(_ set: InstructionSet) {
        if openSetID == set.id {
            commitRename()
            openSetID = nil
            return
        }
        if set.id != model.activeSetID { model.selectSet(set.id) }
        editingName = name(of: set)
        openSetID = set.id
    }

    private var renameRow: some View {
        HStack(spacing: T.s2) {
            TextField(L10n.t("Name"), text: $editingName)
                .textFieldStyle(.plain)
                .font(T.body)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: T.rInner, style: .continuous).fill(T.card2))
                .overlay(RoundedRectangle(cornerRadius: T.rInner, style: .continuous)
                    .strokeBorder(T.accent, lineWidth: 1))
                .frame(maxWidth: 260)
                .focused($nameFocused)
                .onSubmit { commitRename() }
                .onChange(of: nameFocused) { _, focused in
                    if !focused { commitRename() }
                }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.s3)
        .padding(.bottom, T.s2)
    }

    /// 失焦或回车即存；名字空了就退回原名
    private func commitRename() {
        guard !model.isDefaultSet else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == model.activeSetName {
            editingName = model.activeSetName
            return
        }
        model.renameSet(model.activeSetID, to: trimmed)
        editingName = trimmed
    }

    private func isDefault(_ set: InstructionSet) -> Bool { set.id == InstructionSet.defaultID }

    private var setMenuButton: some View {
        IconButton(symbol: "trash", label: L10n.t("Delete this set")) {
            model.creatingSet = false
            model.confirmingDelete = true
        }
    }

    private var newSetButton: some View {
        Button {
            model.setName = ""
            model.creatingSet = true
            model.confirmingDelete = false
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(T.glyph)
                Text(L10n.t("New set"))
            }
        }
        .buttonStyle(PillButtonStyle(kind: .quiet))
    }

    /// 管理窗口提供更大的编辑区；菜单栏面板保持紧凑。
    private var editorHeight: CGFloat {
        let lines = model.draft.split(separator: "\n", omittingEmptySubsequences: false).count
        return presentation == .window
            ? min(max(320, CGFloat(lines) * 19 + 26), 520)
            : min(max(160, CGFloat(lines) * 17 + 26), 180)
    }

    private var createRow: some View {
        HStack(spacing: T.s2) {
            TextField(L10n.t("Name"), text: $model.setName)
                .textFieldStyle(.plain)
                .font(T.body)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: T.rInner, style: .continuous).fill(T.card2))
                .overlay(RoundedRectangle(cornerRadius: T.rInner, style: .continuous)
                    .strokeBorder(T.line, lineWidth: 0.5))
                .onSubmit { model.createSet() }
            IconButton(symbol: "checkmark", label: L10n.t("Save"), tint: T.accent) { model.createSet() }
                .disabled(model.setName.trimmingCharacters(in: .whitespaces).isEmpty)
            IconButton(symbol: "xmark", label: L10n.t("Cancel")) {
                model.creatingSet = false
                model.setName = ""
            }
        }
        .padding(.horizontal, T.s3)
        .padding(.vertical, T.s2)
    }

    private var deleteConfirm: some View {
        HStack(spacing: T.s2) {
            Text(L10n.t("Delete “%@” and its text?", model.activeSetName))
                .font(T.small)
                .foregroundStyle(T.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: T.s2)
            Button(L10n.t("Delete")) { model.deleteActiveSet() }
                .buttonStyle(PillButtonStyle(kind: .danger))
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
}

private struct AgentRow: View {
    @ObservedObject var model: InstructionsModel
    let target: InstructionTarget
    @State private var previewMode: PreviewMode = .diff
    @State private var showsFullPreview = false
    @Environment(\.panelPresentation) private var presentation

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
                    .opacity(on ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 0) {
                    Text(target.name).font(T.body).foregroundStyle(on ? T.fg : T.fg2).lineLimit(1)
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
                if !statusLabel.isEmpty {
                    HStack(spacing: 5) {
                        if target.installed { Circle().fill(statusColor).frame(width: 5, height: 5) }
                        Text(statusLabel).font(T.micro).foregroundStyle(T.muted).lineLimit(1)
                    }
                }
                Button {
                    if expanded { model.expanded.remove(target.id) } else { model.expanded.insert(target.id) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(T.glyph)
                        .foregroundStyle(T.faint)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InteractivePlainButtonStyle())
                .accessibilityLabel(L10n.t("Show the preview"))
                MiniSwitch(isOn: Binding(get: { on }, set: { model.toggle(target, on: $0) }), label: target.name)
                    .disabled(!target.installed)
                    .opacity(target.installed ? 1 : 0.4)
            }
            .padding(.horizontal, T.s3)
            .frame(minHeight: T.rowDouble + 2)

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
                let lines = previewMode == .diff ? diffLines(plan) : fullFileLines(plan)
                let limit = presentation == .window ? 80 : 40
                CodeBlock(lines: showsFullPreview ? lines : Array(lines.prefix(limit)))
                if lines.count > limit {
                    Button(showsFullPreview ? L10n.t("Collapse preview") : L10n.t("Show all %d lines", lines.count)) {
                        showsFullPreview.toggle()
                    }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                }
            }
            if let plan {
                HStack(spacing: T.s2) {
                    SegmentedControl(items: PreviewMode.allCases, selection: $previewMode) { mode in
                        mode == .diff ? L10n.t("Show changes") : L10n.t("Show the whole file")
                    }
                    .frame(width: 168)
                    Text(detail(plan)).font(T.micro).foregroundStyle(T.faint).lineLimit(1)
                    Spacer(minLength: T.s2)
                    Button(L10n.t("Apply")) { model.write(target) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .disabled(!target.installed || !model.isPending(target.id) || model.isDirty)
                }
            }
            backupRow
        }
        .padding(.leading, T.s3 + 18 + T.s2)
        .padding(.trailing, T.s3)
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
                IconButton(
                    symbol: "clock.arrow.circlepath",
                    label: L10n.t("Restore this backup. The current file is backed up first, so this can be undone too.")
                ) { model.restore(latest, to: target) }
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
        return lines
    }

    /// 写入后整份文件的样子，用来确认段落在文件里的位置。
    private func fullFileLines(_ plan: InstructionPlan) -> [DetailLine] {
        let text = plan.resultingFile.isEmpty ? plan.newBlock : plan.resultingFile
        return text.split(separator: "\n", omittingEmptySubsequences: false)
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
        case .unchanged: return on ? T.green : T.faint
        case .skipped: return T.faint
        }
    }
}
