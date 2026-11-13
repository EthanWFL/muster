import MusterCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel
    /// 观察外观：深浅色一变，整块 token 重新求值
    @ObservedObject private var theme = Theme.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            Group {
                if model.showsSettings {
                    SettingsView(store: SettingsStore.shared, model: model)
                } else {
                    tabs
                }
            }
            .transition(.opacity)
            .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: model.showsSettings)

            if let notice = model.notice {
                Text(notice)
                    .font(T.small).foregroundStyle(T.muted)
                    .padding(.horizontal, T.s4).padding(.bottom, T.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            footer
        }
        .frame(width: 420)
        .background(T.bg)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down, action: handleKey)
    }

    /// 顶部：左边品牌，右边 GitHub 与设置
    private var header: some View {
        HStack(spacing: T.s2) {
            BrandMark()
            Text("Muster")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(T.fg)
            Spacer(minLength: T.s2)
            iconButton("arrow.up.right.square", help: L10n.t("Open the GitHub repository"), active: false) {
                if let url = URL(string: "https://github.com/EthanWFL/muster") {
                    NSWorkspace.shared.open(url)
                }
            }
            iconButton(
                "gearshape", help: L10n.t("Settings"), active: model.showsSettings,
                shortcut: ",") {
                model.toggleSettings()
            }
        }
        .padding(.horizontal, T.s3)
        .frame(height: 40)
    }

    private func iconButton(
        _ symbol: String, help: String, active: Bool,
        shortcut: KeyEquivalent? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? T.fg : T.ctlFg)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: T.rInner, style: .continuous)
                    .fill(active ? T.card2 : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(InteractivePlainButtonStyle())
        .help(help)
        .accessibilityLabel(help)
        .modifier(OptionalShortcut(key: shortcut))
    }

    @ViewBuilder private var tabs: some View {
        SegmentedTabs(selection: $model.tab, tabs: model.orderedTabs)
            .padding(.horizontal, T.s3)
            .padding(.top, T.s3)
            .padding(.bottom, T.s2)

        Hairline()

        ScrollView(.vertical) {
                Group {
                    switch model.tab {
                    case .sessions: SessionsView(model: model)
                    case .environment: EnvironmentView(model: model, env: model.env)
                    case .instructions: InstructionsView(model: model.instructions)
                    case .configuration: ConfigurationView(model: model.configuration)
                    }
                }
                .padding(.horizontal, T.s2)
                .padding(.bottom, T.s2)
                .frame(maxWidth: .infinity, minHeight: 240, alignment: .top)
            }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.visible)
        .padding(.bottom, T.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                ShortcutLabel(title: L10n.t("Quit"), glyph: "⌘Q")
            }
            .buttonStyle(PillButtonStyle(kind: .quiet))
            .keyboardShortcut("q")
        }
        .padding(.horizontal, T.s2)
        .frame(height: 40)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if model.showsSettings, press.key == .escape {
            model.showsSettings = false
            return .handled
        }
        return .ignored
    }
}

/// 只在给了键值时挂 ⌘ 快捷键
private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}
