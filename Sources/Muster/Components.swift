import MusterCore
import MusterProtocol
import SwiftUI

// MARK: - Buttons

/// 胶囊按钮：主按钮用系统强调色，次按钮用中性填充，quiet 无底。
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, kind == .quiet ? 8 : 12)
            .frame(height: 28)
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.4)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return .primary
        case .quiet: return .secondary
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return .accentColor
        case .secondary: return Color.primary.opacity(0.10)
        case .quiet: return .clear
        }
    }
}

/// 按钮标题 + 弱化的快捷键字符（不画 keycap 方框）
struct ShortcutLabel: View {
    let title: String
    let glyph: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(glyph).opacity(0.6)
        }
    }
}

// MARK: - Segmented control

/// 分段控件。原生 `Picker(.segmented)` 放不下计数角标，所以自绘，外观贴近系统。
struct SegmentedTabs: View {
    @Binding var selection: PanelModel.Tab
    let badges: [PanelModel.Tab: Int]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelModel.Tab.allCases, id: \.self) { tab in
                Button { selection = tab } label: {
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                        if let n = badges[tab], n > 0 {
                            Text("\(n)")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(.red))
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.12))
                                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Code block

struct DetailLine: Identifiable {
    enum Kind { case plain, add, remove, context }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// 展开行里的命令原文 / 差异预览。内容只用于显示，不落盘。
enum ToolDetail {
    private static let maxLines = 6
    private static let maxLineLength = 200

    static func lines(for call: ToolCall) -> [DetailLine] {
        let input = call.input
        if let command = input["command"]?.stringValue {
            return clipped(command, kind: .plain, prefix: "")
        }
        if let old = input["old_string"]?.stringValue, let new = input["new_string"]?.stringValue {
            return clipped(old, kind: .remove, prefix: "- ") + clipped(new, kind: .add, prefix: "+ ")
        }
        if let content = input["content"]?.stringValue {
            return clipped(content, kind: .add, prefix: "+ ")
        }
        return [DetailLine(kind: .plain, text: ToolSummary.line(tool: call.tool, input: input, cwd: call.cwd, maxLength: 400))]
    }

    private static func clipped(_ text: String, kind: DetailLine.Kind, prefix: String) -> [DetailLine] {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out = all.prefix(maxLines).map { line -> DetailLine in
            let s = line.count > maxLineLength ? String(line.prefix(maxLineLength)) + "…" : String(line)
            return DetailLine(kind: kind, text: prefix + s)
        }
        if all.count > maxLines { out.append(DetailLine(kind: .context, text: "  … \(all.count - maxLines) more lines")) }
        return out
    }
}

struct CodeBlock: View {
    let lines: [DetailLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(color(line.kind))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private func color(_ kind: DetailLine.Kind) -> Color {
        switch kind {
        case .plain: return .primary
        case .add: return .green
        case .remove: return .red
        case .context: return .secondary
        }
    }
}
