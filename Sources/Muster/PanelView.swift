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

            if let action = model.pendingHookAction { hookConfirm(action) }
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
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .modifier(OptionalShortcut(key: shortcut))
    }

    @ViewBuilder private var tabs: some View {
        SegmentedTabs(
            selection: $model.tab, tabs: model.orderedTabs,
            badges: [.approvals: model.pending.count])
            .padding(.horizontal, T.s3)
            .padding(.top, T.s3)
            .padding(.bottom, T.s2)

        Hairline()

        ScrollView(.vertical) {
                Group {
                    switch model.tab {
                    case .approvals: ApprovalsView(model: model, returnFocus: { focused = true })
                    case .sessions: SessionsView(model: model)
                    case .environment: EnvironmentView(model: model, env: model.env)
                    case .instructions: InstructionsView(model: model.instructions)
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

    private func hookConfirm(_ action: PanelModel.HookAction) -> some View {
        VStack(alignment: .leading, spacing: T.s2) {
            Text(L10n.t(
                action == .install
                    ? "Add the Muster PreToolUse hook to %@? A backup is made first."
                    : "Remove only the Muster hook from %@? A backup is made first.",
                model.settingsPath
            ))
            .font(T.body)
            .foregroundStyle(T.fg)
            HStack(spacing: T.s2) {
                Button(L10n.t("Confirm")) { model.confirmHookAction() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                Button(L10n.t("Cancel")) { model.cancelHookAction() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
        .padding(.horizontal, T.s4)
        .padding(.bottom, T.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // 永久允许的二次确认优先：只接受 ⏎ / Esc，其余按键不改变选择
        if model.pendingPermanentAllow != nil {
            switch press.key {
            case .return:
                model.confirmPermanentAllow()
            case .escape:
                model.cancelPermanentAllow()
            default:
                return .ignored
            }
            return .handled
        }
        // 设置页里 ⎋ 退回主视图
        if model.showsSettings {
            if press.key == .escape {
                model.showsSettings = false
                return .handled
            }
            return .ignored
        }
        // 编辑拒绝原因时按键归输入框；非审批页不抢键
        guard model.denyDraft == nil, model.tab == .approvals else { return .ignored }
        switch press.key {
        case .return:
            if press.modifiers.contains(.shift) {
                model.beginPermanentAllow()
            } else if press.modifiers.contains(.command) {
                model.jumpToTerminal()
            } else if press.modifiers.contains(.option) {
                model.allowSimilarSelected()
            } else {
                model.allowSelected()
            }
            return .handled
        case .delete, .deleteForward:
            model.beginDeny()
            return .handled
        case .downArrow:
            model.moveSelection(by: 1)
            return .handled
        case .upArrow:
            model.moveSelection(by: -1)
            return .handled
        default:
            switch press.characters {
            case "j": model.moveSelection(by: 1); return .handled
            case "k": model.moveSelection(by: -1); return .handled
            default: return .ignored
            }
        }
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
