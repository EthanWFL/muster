import MusterCore
import SwiftUI

struct ConfigurationView: View {
    @ObservedObject var model: ConfigurationModel
    var showsAgentPicker = true
    var compact = false
    @State private var confirmsRestore = false
    @State private var confirmsReload = false

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 0) {
                    ScrollView { compactContent.padding(T.s2) }.scrollBounceBehavior(.basedOnSize)
                    if let message = model.errorMessage ?? model.notice {
                        Text(message).font(T.small).foregroundStyle(model.errorMessage == nil ? T.muted : T.red)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, T.s3).padding(.vertical, T.s2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Hairline()
                    if model.selected?.editable == true, model.snapshot != nil {
                        actionBar.padding(.vertical, T.s1)
                    } else if model.selected != nil {
                        HStack {
                            Text(L10n.t("File access only")).font(T.small).foregroundStyle(T.muted)
                            Spacer()
                            Button(L10n.t("Open file")) { model.openFile() }.buttonStyle(PillButtonStyle(kind: .primary))
                        }.padding(.horizontal, T.s3).frame(height: T.rowDouble + 8)
                    }
                }
            } else { standardContent }
        }
        .onAppear { model.loadIfNeeded() }
        .alert(L10n.t("Discard unsaved changes?"), isPresented: $confirmsReload) {
            Button(L10n.t("Discard"), role: .destructive) { model.reload() }
            Button(L10n.t("Cancel"), role: .cancel) {}
        }
        .alert(L10n.t("Restore the configuration before the last Muster save?"), isPresented: $confirmsRestore) {
            Button(L10n.t("Restore previous"), role: .destructive) { model.restore() }
            Button(L10n.t("Cancel"), role: .cancel) {}
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            if let selected = model.selected {
                if selected.editable, let snapshot = model.snapshot {
                    HStack {
                        SectionTitle(text: L10n.t("Default model"))
                        if !model.presets.isEmpty {
                            Menu {
                                ForEach(model.presets) { preset in
                                    Button(preset.name + " · " + preset.model) { model.usePreset(preset) }
                                }
                            } label: { CompactMenuLabel(title: L10n.t("Use preset")) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .disabled(model.dirty).padding(.trailing, T.s3)
                        }
                    }
                    modelCard(selected, snapshot)
                    Text(L10n.t("Saved defaults apply to new Agent sessions."))
                        .font(T.small).foregroundStyle(T.muted).padding(.horizontal, T.s3)
                    DisclosureGroup(L10n.t("Configuration file")) { fileCard(selected).padding(.top, T.s2) }
                        .font(T.small).foregroundStyle(T.muted).padding(T.s3)
                } else { fileCard(selected) }
            }
        }
    }

    private var standardContent: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Agent configuration"))
            if let selected = model.selected {
                header(selected)
                fileCard(selected)
                if selected.editable, let snapshot = model.snapshot {
                    SectionTitle(text: L10n.t("Default model"))
                    modelCard(selected, snapshot)
                    presetsCard
                    Text(L10n.t("These are user-level startup defaults. Project settings, profiles and launch options may override them."))
                        .font(T.micro).foregroundStyle(T.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, T.s3)
                }
            } else {
                EmptyState(title: L10n.t("No configurations found"),
                           message: L10n.t("Agents with existing configuration files show up here."))
            }
            if model.dirty {
                Text(L10n.t("Save or discard changes before switching agents."))
                    .font(T.micro).foregroundStyle(T.muted).padding(.horizontal, T.s3)
            }
            if let notice = model.notice {
                Text(notice).font(T.micro).foregroundStyle(T.muted).padding(.horizontal, T.s3)
            }
            if let error = model.errorMessage {
                Text(error).font(T.micro).foregroundStyle(T.red).padding(.horizontal, T.s3)
            }
        }
    }

    // MARK: 顶部

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Model presets"), count: model.presets.count)
            Card {
                ForEach(model.presets) { preset in
                    HStack(spacing: T.s2) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).font(T.body)
                            Text(preset.provider + " / " + preset.model).font(T.monoMicro).foregroundStyle(T.muted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(L10n.t("Use preset")) { model.usePreset(preset) }
                            .buttonStyle(PillButtonStyle(kind: .secondary)).disabled(model.dirty)
                        IconButton(symbol: "trash", label: L10n.t("Delete preset"), tint: T.ctlFg) { model.removePreset(preset) }
                    }
                    .padding(.horizontal, T.s3).frame(minHeight: T.rowDouble)
                    Hairline()
                }
                HStack(spacing: T.s2) {
                    TextField(L10n.t("Preset name"), text: $model.presetName)
                        .textFieldStyle(.roundedBorder).font(T.body)
                    Button(L10n.t("Save preset")) { model.savePreset() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .disabled(model.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(T.s3)
            }
        }
    }

    private func header(_ selected: AgentConfiguration) -> some View {
        HStack(spacing: T.s2) {
            AgentLogo(agentID: selected.id, mark: selected.id == "pi" ? "π" : String(selected.name.prefix(1)))
            if showsAgentPicker {
                InlineSelect(items: model.targets, label: { $0.name },
                         selection: Binding(get: { selected }, set: { model.select($0) }))
                .disabled(model.dirty)
            } else { Text(selected.name).font(T.body) }
            Spacer()
            IconButton(symbol: "arrow.clockwise", label: L10n.t("Reload")) {
                if model.dirty { confirmsReload = true } else { model.reload() }
            }
        }
        .padding(.horizontal, T.s3)
        .zIndex(2)
    }

    /// 配置文件：路径、大小、修改时间放在最前；改不了的 agent 在这里直接给「打开文件」
    private func fileCard(_ selected: AgentConfiguration) -> some View {
        Card {
            HStack(spacing: T.s2) {
                VStack(alignment: .leading, spacing: 1) {
                    Text((selected.path as NSString).abbreviatingWithTildeInPath)
                        .font(T.monoMicro).foregroundStyle(T.fg2)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(selected.path)
                    if let info = model.fileInfo {
                        Text(info).font(T.micro).foregroundStyle(T.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !compact { IconButton(symbol: "doc.text", label: L10n.t("Open file")) { model.openFile() } }
                IconButton(symbol: "folder", label: L10n.t("Show in Finder")) { model.revealFile() }
            }
            .padding(.horizontal, T.s3)
            .frame(minHeight: T.rowDouble)
            if !selected.editable {
                Hairline()
                HStack(spacing: T.s2) {
                    Text(L10n.t("Edit this agent in its original configuration file. Model editing here currently supports Codex and Pi."))
                        .font(T.small).foregroundStyle(T.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: T.s2)
                    if !compact {
                    Button(L10n.t("Open file")) { model.openFile() }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                    }
                }
                .padding(.horizontal, T.s3)
                .padding(.vertical, T.s2)
            }
        }
    }

    // MARK: 默认模型

    /// 有本地模型列表就用下拉选，手填收进「自定义…」；没有列表时直接是两个输入框。
    private func modelCard(_ selected: AgentConfiguration, _ snapshot: ConfigurationSnapshot) -> some View {
        let listing = model.choices.count > 1 && !model.customEntry
        return Card {
            if listing {
                SettingsRow(label: L10n.t("Model")) {
                    InlineSelect(
                        items: model.availableChoices, label: { $0.label },
                        header: L10n.t("Local models"),
                        selection: Binding(
                            get: { model.currentChoice },
                            set: { model.provider = $0.provider; model.model = $0.model }),
                        customAction: { model.customEntry = true })
                        .frame(maxWidth: 240, alignment: .trailing)
                }
                .zIndex(1)   // 下拉是浮层，要压在下面的 diff 和操作栏之上
            } else {
                SettingsRow(label: L10n.t("Provider")) {
                    MiniField(placeholder: L10n.t("Provider"), text: $model.provider, width: 200)
                }
                Hairline()
                SettingsRow(label: L10n.t("Model ID")) {
                    MiniField(placeholder: L10n.t("Model ID"), text: $model.model, width: 200)
                }
                if model.choices.count > 1 {
                    Hairline()
                    HStack {
                        Spacer()
                        Button(L10n.t("Local models")) { model.customEntry = false }
                            .buttonStyle(PillButtonStyle(kind: .quiet))
                    }
                    .padding(.horizontal, T.s3)
                    .frame(height: T.rowCompact)
                }
            }
            if model.dirty {
                Hairline()
                CodeBlock(lines: diffLines(selected, snapshot))
                    .padding(.horizontal, T.s3)
                    .padding(.vertical, T.s2)
            }
            if !compact { Hairline(); actionBar }
        }
        .zIndex(1)
    }

    /// 左：恢复上次；右：放弃 + 保存。和规则页底栏同一套。
    private var actionBar: some View {
        HStack(spacing: T.s2) {
            Button(L10n.t("Restore previous")) { confirmsRestore = true }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .disabled(!model.canRestore || model.dirty || !model.canWrite)
            Spacer(minLength: T.s2)
            if model.dirty {
                Button(L10n.t("Discard")) { model.reload() }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
            }
            Button { model.save() } label: {
                SaveStateLabel(title: model.dirty ? L10n.t("Save") : L10n.t("Saved"),
                               glyph: "⌘S", isSaved: !model.dirty && model.errorMessage == nil)
            }
            .buttonStyle(PillButtonStyle(kind: model.dirty ? .primary : .secondary))
            .disabled(!model.dirty || !model.canWrite)
            .keyboardShortcut("s", modifiers: .command)
            .help(L10n.t("A private backup is saved before writing."))
        }
        .padding(.horizontal, T.s3)
        .frame(height: T.rowDouble)
    }

    /// 改了哪个字段、从什么到什么；键名用文件里真实的键
    private func diffLines(_ selected: AgentConfiguration, _ snapshot: ConfigurationSnapshot) -> [DetailLine] {
        let separator = selected.id == "pi" ? ": " : " = "
        var lines: [DetailLine] = []
        for (key, old, new) in [(selected.providerKey, snapshot.provider, model.provider),
                                (selected.modelKey, snapshot.model, model.model)] where old != new {
            lines.append(DetailLine(kind: .remove, text: "- " + key + separator + (old.isEmpty ? L10n.t("Automatic") : old)))
            lines.append(DetailLine(kind: .add, text: "+ " + key + separator + new))
        }
        return lines
    }
}
