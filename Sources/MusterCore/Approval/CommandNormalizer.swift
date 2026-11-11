import Foundation
import MusterProtocol

/// 生成 R5 折叠用的规范化键。只合并「肯定等价」的写法：引号内的空白保持原样，
/// 宁可少折叠，也不能把两条不同的命令当成同一条让用户误批。
enum CommandNormalizer {
    /// 引号外的连续空白折成一个空格（含换行的折成 `\n`）；首尾空白去掉。
    /// 引号不配对时原样返回（trim 后），不做任何折叠。
    static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        var inSingle = false
        var inDouble = false
        var pendingSpace = false
        var pendingNewline = false
        var iterator = s.makeIterator()

        func flush() {
            if !out.isEmpty {
                if pendingNewline { out.append("\n") } else if pendingSpace { out.append(" ") }
            }
            pendingSpace = false
            pendingNewline = false
        }

        while let ch = iterator.next() {
            if inSingle {
                out.append(ch)
                if ch == "'" { inSingle = false }
                continue
            }
            if ch == "\\" {
                flush()
                out.append(ch)
                if let next = iterator.next() { out.append(next) }
                continue
            }
            if inDouble {
                out.append(ch)
                if ch == "\"" { inDouble = false }
                continue
            }
            if ch == "\n" || ch == "\r" { pendingNewline = true; continue }
            if ch == " " || ch == "\t" { pendingSpace = true; continue }
            flush()
            out.append(ch)
            if ch == "'" { inSingle = true } else if ch == "\"" { inDouble = true }
        }
        if inSingle || inDouble { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return out
    }

    /// 折叠键里「命令」那一段：shell 工具用规范化后的命令文本，其余工具用键排序后的 JSON。
    static func fingerprint(tool: String, input: [String: JSONValue]) -> String {
        if RiskTables.shellTools.contains(tool.lowercased()) {
            if let command = RiskClassifier.commandText(from: input) { return collapseWhitespace(command) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(input), let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}
