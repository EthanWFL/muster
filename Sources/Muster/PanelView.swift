import MusterCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SegmentedTabs(selection: $model.tab, badges: [.approvals: model.pending.count])
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Group {
                switch model.tab {
                case .approvals: ApprovalsView(model: model, returnFocus: { focused = true })
                case .sessions: SessionsView(model: model)
                case .environment: EnvironmentView(model: model, env: model.env)
                case .rules: RulesView(rules: model.rules)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .top)

            if let action = model.pendingHookAction { hookConfirm(action) }
            if let notice = model.notice {
                Text(notice)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 420)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down, action: handleKey)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            if let installed = model.hookInstalled {
                Button(installed ? L10n.t("Uninstall hook") : L10n.t("Install hook")) {
                    model.requestHook(installed ? .uninstall : .install)
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
            }
            Spacer()
            Button { SettingsCoordinator.shared.show(model: model) } label: {
                ShortcutLabel(title: L10n.t("Settings"), glyph: "⌘,")
            }
            .buttonStyle(PillButtonStyle(kind: .quiet))
            .keyboardShortcut(",", modifiers: .command)
            Button { NSApplication.shared.terminate(nil) } label: { ShortcutLabel(title: L10n.t("Quit"), glyph: "⌘Q") }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }

    private func hookConfirm(_ action: PanelModel.HookAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t(
                action == .install
                    ? "Add the Muster PreToolUse hook to %@? A backup is made first."
                    : "Remove only the Muster hook from %@? A backup is made first.",
                model.settingsPath
            ))
            .font(.subheadline)
            HStack {
                Button(L10n.t("Confirm")) { model.confirmHookAction() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                Button(L10n.t("Cancel")) { model.cancelHookAction() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
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
