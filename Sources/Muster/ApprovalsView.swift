import MusterCore
import MusterProtocol
import SwiftUI

struct ApprovalsView: View {
    @ObservedObject var model: PanelModel
    let returnFocus: () -> Void

    var body: some View {
        if model.pending.isEmpty {
            VStack(spacing: 4) {
                Text(L10n.t("Nothing waiting")).fontWeight(.semibold)
                Text(L10n.t("Requests from your agents appear here")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else {
            // 只在面板可见时每秒刷新一次，用于等待时长和倒计时线
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 2) {
                    ForEach(model.pending) { call in
                        ApprovalRow(
                            model: model, call: call, now: context.date,
                            selected: call.id == model.selection, returnFocus: returnFocus)
                    }
                }
            }
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
            HStack(spacing: 8) {
                Circle().fill(riskColor).frame(width: 8, height: 8)
                Text(parts.tool).fontWeight(.semibold)
                Text(parts.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if call.repeatCount > 1 {
                    Text("×\(call.repeatCount)").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("\(elapsed)s").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Text("\((call.cwd as NSString).abbreviatingWithTildeInPath) · \(call.agent.rawValue)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(riskLabel).foregroundStyle(riskColor)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
            .padding(.top, 2)

            if selected {
                ApprovalDetail(model: model, call: call, remaining: remaining, returnFocus: returnFocus)
                    .padding(.top, 12)
            }

            // 90s 超时倒计时：这个面板的标志性细节，最后 15s 变红
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(urgent ? Color.red : Color.primary.opacity(0.3))
                        .frame(width: g.size.width * CGFloat(remaining / max(model.approvalTimeout, 1)))
                }
            }
            .frame(height: 2)
            .padding(.top, 8)
            .animation(.linear(duration: 1), value: remaining)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            guard model.selection != call.id else { return }
            model.clearPermanentAllow()
            model.denyDraft = nil
            model.selection = call.id
        }
    }

    private var riskColor: Color {
        switch call.risk {
        case .high: return .red
        case .medium: return .orange
        case .low: return Color.secondary
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
        VStack(alignment: .leading, spacing: 12) {
            CodeBlock(lines: ToolDetail.lines(for: call))

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    Text(L10n.t("Folder")).foregroundStyle(.secondary)
                    Text((call.cwd as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                }
                GridRow {
                    Text(L10n.t("Session")).foregroundStyle(.secondary)
                    Text("\(call.agent.rawValue) · \(call.sessionID.prefix(8))")
                }
                GridRow {
                    Text(L10n.t("Expires")).foregroundStyle(.secondary)
                    Text(L10n.t(
                        "in %ds, then %@ asks you itself",
                        Int(remaining.rounded(.up)),
                        call.agent.rawValue
                    ))
                    .monospacedDigit()
                }
                GridRow {
                    Text(L10n.t("Terminal")).foregroundStyle(.secondary)
                    Button { model.jumpToTerminal() } label: {
                        ShortcutLabel(title: L10n.t("Show"), glyph: "⌘⏎")
                    }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .help(L10n.t("Focus the terminal window running this session. If it cannot be found, the folder path is copied."))
                }
            }
            .font(.subheadline)

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
        HStack(spacing: 8) {
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
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("Always allow this exact command?"))
                .font(.subheadline.weight(.medium))
            CodeBlock(lines: [DetailLine(kind: .plain, text: "permissions.allow += \(prompt.rule.text)")])
            Text(L10n.t(
                "Adds the line above to %@. A backup is written first, and this survives the session. Only an identical command matches.",
                model.settingsPath
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(L10n.t("Reason sent to the agent"), text: Binding(
                    get: { model.denyDraft ?? "" }, set: { model.denyDraft = $0 }))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5))
                    .focused($reasonFocused)
                    .onSubmit { model.confirmDeny(); returnFocus() }
                    .onExitCommand { model.cancelDeny(); returnFocus() }
                Button { model.confirmDeny(); returnFocus() } label: { ShortcutLabel(title: L10n.t("Deny"), glyph: "⏎") }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
            Text(L10n.t("The agent receives this reason · Esc to cancel"))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .onAppear { reasonFocused = true }
    }
}
