import MusterCore
import SwiftUI

struct ConfigurationView: View {
    @ObservedObject var model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Agent configuration"))
            if let selected = model.selected {
                HStack(spacing: T.s2) {
                    AgentLogo(agentID: selected.id, mark: selected.id == "pi" ? "π" : String(selected.name.prefix(1)))
                    InlineSelect(items: model.targets, label: { $0.name }, alignment: .leading,
                        selection: Binding(get: { selected }, set: { model.select($0) })) {
                            EmptyView()
                        }
                        .disabled(model.dirty)
                    Spacer()
                    Button(L10n.t("Reload")) {
                        if model.dirty { model.confirmingReload = true } else { model.reload() }
                    }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                }
                .padding(.horizontal, T.s3)
                .zIndex(2)

                if selected.editable, let snapshot = model.snapshot {
                    Card {
                        VStack(alignment: .leading, spacing: T.s3) {
                            field(L10n.t("Provider"), text: $model.provider)
                            field(L10n.t("Model ID"), text: $model.model)
                            if model.choices.count > 1 {
                                InlineSelect(items: model.availableChoices, label: { $0.label },
                                    header: L10n.t("Local models"), width: 330, maxListHeight: 180, alignment: .leading,
                                    selection: Binding(
                                        get: { model.currentChoice },
                                        set: { model.provider = $0.provider; model.model = $0.model })) {
                                            EmptyView()
                                        }
                            }
                            Text(L10n.t("Choose a local model or enter an ID. Existing provider credentials are reused."))
                                .font(T.micro).foregroundStyle(T.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(T.s3)
                    }
                    .zIndex(1)

                    if model.previewing {
                        Card {
                            VStack(alignment: .leading, spacing: T.s2) {
                                Text(L10n.t("Review changes")).font(T.body)
                                if model.provider != snapshot.provider {
                                    change(L10n.t("Provider"), from: snapshot.provider, to: model.provider)
                                }
                                if model.model != snapshot.model {
                                    change(L10n.t("Model ID"), from: snapshot.model, to: model.model)
                                }
                                Text(L10n.t("A private backup is saved before writing."))
                                    .font(T.micro).foregroundStyle(T.muted)
                                HStack {
                                    Button(L10n.t("Save")) { model.save() }
                                        .buttonStyle(PillButtonStyle(kind: .primary))
                                    Button(L10n.t("Cancel")) { model.previewing = false }
                                        .buttonStyle(PillButtonStyle(kind: .secondary))
                                }
                            }.padding(T.s3)
                        }
                    } else {
                        HStack {
                            Button(L10n.t("Review changes")) { model.preview() }
                                .buttonStyle(PillButtonStyle(kind: .primary))
                                .disabled(!model.dirty)
                                .keyboardShortcut("s", modifiers: .command)
                            Spacer()
                            Button(L10n.t("Restore previous")) { model.confirmingRestore = true }
                                .buttonStyle(PillButtonStyle(kind: .secondary))
                                .disabled(!model.canRestore || model.dirty)
                        }.padding(.horizontal, T.s3)
                    }
                    Text(L10n.t("These are user-level startup defaults. Project settings, profiles and launch options may override them."))
                        .font(T.micro).foregroundStyle(T.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, T.s3)
                } else if !selected.editable {
                    Text(L10n.t("Edit this agent in its original configuration file. Model editing here currently supports Codex and Pi."))
                        .font(T.small).foregroundStyle(T.muted)
                        .padding(T.s3)
                }

                SectionTitle(text: L10n.t("Configuration file"))
                Card {
                    VStack(alignment: .leading, spacing: T.s2) {
                        Text((selected.path as NSString).abbreviatingWithTildeInPath)
                            .font(T.monoMicro).foregroundStyle(T.fg2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(L10n.t("Open file")) { model.openFile() }
                            Button(L10n.t("Show in Finder")) { model.revealFile() }
                        }.buttonStyle(PillButtonStyle(kind: .secondary))
                    }.padding(T.s3)
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
        .onAppear { model.loadIfNeeded() }
        .alert(L10n.t("Discard unsaved changes?"), isPresented: $model.confirmingReload) {
            Button(L10n.t("Discard"), role: .destructive) { model.reload() }
            Button(L10n.t("Cancel"), role: .cancel) {}
        }
        .alert(L10n.t("Restore the configuration before the last Muster save?"), isPresented: $model.confirmingRestore) {
            Button(L10n.t("Restore previous"), role: .destructive) { model.restore() }
            Button(L10n.t("Cancel"), role: .cancel) {}
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: T.s1) {
            Text(title).font(T.small).foregroundStyle(T.muted)
            TextField(title, text: text)
                .font(T.mono).textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
    }

    private func change(_ title: String, from old: String, to new: String) -> some View {
        VStack(alignment: .leading, spacing: T.s1) {
            Text(title).font(T.small).foregroundStyle(T.muted)
            Text("− " + (old.isEmpty ? L10n.t("Automatic") : old)).foregroundStyle(T.muted)
            Text("+ " + new).foregroundStyle(T.fg)
        }.font(T.monoMicro).textSelection(.enabled)
    }
}
