import Foundation
import MusterProtocol

/// 每个请求的一行摘要，例如 `Bash: rm -rf ./build`、`Edit: src/app.ts`。
public enum ToolSummary {
    static let pathKeys = ["file_path", "path", "notebook_path", "filePath", "target_file", "file"]
    static let textKeys = ["pattern", "query", "url", "description", "prompt"]

    public static func line(tool: String, input: [String: JSONValue], cwd: String? = nil, maxLength: Int = 100) -> String {
        let lower = tool.lowercased()
        let name = RiskTables.shellTools.contains(lower) ? "Bash" : tool
        guard let detail = detail(lower: lower, input: input, cwd: cwd) else { return clip(name, maxLength) }
        return clip("\(name): \(detail)", maxLength)
    }

    private static func detail(lower: String, input: [String: JSONValue], cwd: String?) -> String? {
        if RiskTables.shellTools.contains(lower) {
            return RiskClassifier.commandText(from: input).map(oneLine)
        }
        let path = pathKeys.lazy.compactMap { input[$0]?.stringValue }.first(where: { !$0.isEmpty })
        let text = textKeys.lazy.compactMap { input[$0]?.stringValue }.first(where: { !$0.isEmpty })
        switch (path, text) {
        case let (p?, t?) where lower.contains("grep") || lower.contains("search"):
            return "\(oneLine(t)) in \(relative(p, to: cwd))"
        case let (p?, _): return relative(p, to: cwd)
        case let (_, t?): return oneLine(t)
        default: return nil
        }
    }

    static func relative(_ path: String, to cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return oneLine(path) }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return oneLine(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path)
    }

    /// 摘要只用于显示：换行画成 ⏎，其他控制字符丢弃，连续空白折成一个空格
    static func oneLine(_ s: String) -> String {
        var out = ""
        var lastSpace = false
        for ch in CommandNormalizer.collapseWhitespace(s) {
            if ch == "\n" { out += " ⏎ "; lastSpace = true; continue }
            if ch.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { continue }
            if ch == " " { if !lastSpace { out.append(ch) }; lastSpace = true; continue }
            out.append(ch)
            lastSpace = false
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func clip(_ s: String, _ max: Int) -> String {
        guard max > 1, s.count > max else { return s }
        return String(s.prefix(max - 1)) + "…"
    }
}
