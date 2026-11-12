import MusterCore
import MusterProtocol
import SwiftUI

struct ApprovalsView: View {
    @ObservedObject var model: PanelModel
    let returnFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            hookRow
            if model.pending.isEmpty {
                EmptyState(
                    title: L10n.t("Nothing waiting"),
                    message: L10n.t("Requests from your agents appear here"))
            } else {
                // 只在面板可见时每秒刷新一次，用于等待时长和倒计时线
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Card {
                        ForEach(Array(model.pending.enumerated()), id: \.element.id) { index, call in
                            ApprovalRow(
                                model: model, call: call, now: context.date,
                                selected: call.id == model.selection, returnFocus: returnFocus)
                            if index < model.pending.count - 1 { Hairline() }
                        }
                    }
                }
            }
        }
    }

    /// 没装 hook 时才在审批页提示（没有 hook 就没有审批流）；装好之后不再占行
    @ViewBuilder private var hookRow: some View {
        if model.hookInstalled == false {
            HStack(spacing: T.s2) {
                Text(L10n.t("PreToolUse hook"))
                    .font(T.small)
                    .foregroundStyle(T.muted)
                Spacer(minLength: T.s2)
                Button(L10n.t("Install hook")) {
                    model.requestHook(.install)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            .padding(.horizontal, T.s3)
            .frame(height: T.rowCompact)
        }
    }
}

private struct ApprovalRow: View {
    @ObservedObject var model: PanelModel
    let call: ToolCall
    let now: Date
    let selected: Bool
    let returnFocus: () -> Void

    private var deadline: Date { call.requestedAt.addingTimeInterval(model.approvalTimeout) }
    private var remaining: TimeInterval { max(0, deadline.timeIntervalSince(now)) }
    private var elapsed: Int { max(0, Int(now.timeIntervalSince(call.requestedAt))) }
    private var urgent: Bool { remaining <= 15 }

    /// `ToolSummary.line` 形如 "Bash: rm -rf ./build"，拆成工具名和摘要两段分别排版
    private var parts: (tool: String, summary: String) {
        let line = ToolSummary.line(tool: call.tool, input: call.input, cwd: call.cwd)
        guard let r = line.range(of: ": ") else { return (line, "") }
        return (String(line[..<r.lowerBound]), String(line[r.upperBound...]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: T.s2) {
                StatusDot(tone: riskTone)
                Text(parts.tool).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(T.fg)
                Text(parts.summary)
                    .font(T.mono)
                    .foregroundStyle(T.fg2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if call.repeatCount > 1 {
                    Text("×\(call.repeatCount)").font(T.micro).foregroundStyle(T.muted)
                }
                Text("\(elapsed)s").font(T.monoMicro).monospacedDigit().foregroundStyle(T.faint)
            }
            HStack {
                Text("\((call.cwd as NSString).abbreviatingWithTildeInPath) · \(call.agent.rawValue)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: T.s2)
                Text(riskLabel).foregroundStyle(riskTone.color)
            }
            .font(T.small)
            .foregroundStyle(T.muted)
            .padding(.leading, 15)
            .padding(.top, 2)

            if selected {
                ApprovalDetail(model: model, call: call, remaining: remaining, returnFocus: returnFocus)
                    .padding(.top, T.s3)
            }

            // 90s 超时倒计时：这个面板的标志性细节，最后 15s 变红
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(T.segTrack)
                    Capsule()
                        .fill(urgent ? T.red : T.ctlFg)
                        .frame(width: g.size.width * CGFloat(remaining / max(model.approvalTimeout, 1)))
                }
            }
            .frame(height: 2)
            .padding(.top, T.s2)
            .animation(.linear(duration: 1), value: remaining)
        }
        .padding(.horizontal, T.s3)
        .padding(.vertical, T.s2)
        .background(RoundedRectangle(cornerRadius: T.r, style: .continuous)
            .fill(selected ? T.card2 : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            guard model.selection != call.id else { return }
            model.clearPermanentAllow()
            model.denyDraft = nil
            model.selection = call.id
        }
    }

    private var riskTone: StatusTone {
        switch call.risk {
        case .high: return .failed
        case .medium: return .waiting
        case .low: return .neutral
        }
    }

    private var riskLabel: String {
        switch call.risk {
        case .high: return L10n.t("High")
        case .medium: return L10n.t("Medium")
        case .low: return L10n.t("Low")
        }
    }
}

private struct ApprovalDetail: View {
    @ObservedObject var model: PanelModel
    let call: ToolCall
    let remaining: TimeInterval
    let returnFocus: () -> Void
    @FocusState private var reasonFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            CodeBlock(lines: ToolDetail.lines(for: call))

            Grid(alignment: .leading, horizontalSpacing: T.s2, verticalSpacing: 2) {
                GridRow {
                    Text(L10n.t("Folder")).foregroundStyle(T.muted)
                    Text((call.cwd as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                }
                GridRow {
                    Text(L10n.t("Session")).foregroundStyle(T.muted)
                    Text("\(call.agent.rawValue) · \(call.sessionID.prefix(8))")
                }
                GridRow {
                    Text(L10n.t("Expires")).foregroundStyle(T.muted)
                    Text(L10n.t(
                        "in %ds, then %@ asks you itself",
                        Int(remaining.rounded(.up)),
                        call.agent.rawValue
                    ))
                    .monospacedDigit()
                }
                GridRow {
                    Text(L10n.t("Terminal")).foregroundStyle(T.muted)
                    Button { model.jumpToTerminal() } label: {
                        ShortcutLabel(title: L10n.t("Show"), glyph: "⌘⏎")
                    }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .help(L10n.t("Focus the terminal window running this session. If it cannot be found, the folder path is copied."))
                }
            }
            .font(T.small)
            .foregroundStyle(T.fg2)

            if let prompt = model.pendingPermanentAllow, prompt.callID == call.id {
                permanentPrompt(prompt)
            } else if model.denyDraft != nil {
                reasonEditor
            } else {
                actions
            }
        }
    }

    private var actions: some View {
        HStack(spacing: T.s2) {
            Button { model.allowSelected() } label: { ShortcutLabel(title: L10n.t("Allow"), glyph: "⏎") }
                .buttonStyle(PillButtonStyle(kind: .primary))
            Button { model.beginDeny() } label: { ShortcutLabel(title: L10n.t("Deny"), glyph: "⌫") }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            Button { model.allowSimilarSelected() } label: { ShortcutLabel(title: L10n.t("Similar"), glyph: "⌥⏎") }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(!model.canAllowSimilar(call.id))
                .help(L10n.t("Allow the same tool and command prefix for the rest of this session. Not offered for high-risk commands."))
            Button { model.beginPermanentAllow() } label: { ShortcutLabel(title: L10n.t("Always"), glyph: "⇧⏎") }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(!model.canAlwaysAllow(call.id))
                .help(L10n.t("Save this exact command to Claude's permissions.allow, after showing you the line."))
        }
    }

    private func permanentPrompt(_ prompt: PanelModel.PermanentAllowPrompt) -> some View {
        VStack(alignment: .leading, spacing: T.s2) {
            Text(L10n.t("Always allow this exact command?"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(T.fg)
            CodeBlock(lines: [DetailLine(kind: .plain, text: "permissions.allow += \(prompt.rule.text)")])
            Text(L10n.t(
                "Adds the line above to %@. A backup is written first, and this survives the session. Only an identical command matches.",
                model.settingsPath
            ))
            .font(T.small)
            .foregroundStyle(T.muted)
            HStack(spacing: T.s2) {
                Button { model.confirmPermanentAllow(); returnFocus() } label: {
                    ShortcutLabel(title: L10n.t("Allow & save"), glyph: "⏎")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                Button { model.cancelPermanentAllow(); returnFocus() } label: {
                    ShortcutLabel(title: L10n.t("Cancel"), glyph: "esc")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
    }

    private var reasonEditor: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            HStack(spacing: T.s2) {
                TextField(L10n.t("Reason sent to the agent"), text: Binding(
                    get: { model.denyDraft ?? "" }, set: { model.denyDraft = $0 }))
                    .textFieldStyle(.plain)
                    .font(T.body)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: T.rInner, style: .continuous).fill(T.card2))
                    .overlay(RoundedRectangle(cornerRadius: T.rInner, style: .continuous)
                        .strokeBorder(T.accent, lineWidth: 1))
                    .focused($reasonFocused)
                    .onSubmit { model.confirmDeny(); returnFocus() }
                    .onExitCommand { model.cancelDeny(); returnFocus() }
                Button { model.confirmDeny(); returnFocus() } label: { ShortcutLabel(title: L10n.t("Deny"), glyph: "⏎") }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
            Text(L10n.t("The agent receives this reason · Esc to cancel"))
                .font(T.small).foregroundStyle(T.muted)
        }
        .onAppear { reasonFocused = true }
    }
}
