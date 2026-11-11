import Foundation

/// Splits a rule file into entries, one per list item or paragraph (R12).
///
/// This is deliberately not a Markdown parser. It only knows about:
/// - blank lines (end an entry),
/// - list markers (`-`, `*`, `+`, `1.`, `1)`) which start a new entry,
/// - fenced code blocks and headings, which are skipped (they are not rules),
/// - horizontal rules, which are skipped.
public enum RuleParser {
    public static func parse(_ text: String) -> [ParsedRuleEntry] {
        var entries: [ParsedRuleEntry] = []
        var startLine = 0
        var lines: [String] = []
        var fence: String?

        func flush() {
            defer { lines.removeAll(keepingCapacity: true) }
            guard let first = lines.firstIndex(where: { !$0.isEmpty }) else { return }
            let body = lines[first...].joined(separator: "\n")
            entries.append(ParsedRuleEntry(line: startLine + first, text: body))
        }

        let all = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        for (offset, rawLine) in all.enumerated() {
            let lineNo = offset + 1
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                fence = String(trimmed.prefix(3))
                continue
            }
            if trimmed.isEmpty || isHeading(trimmed) || isHorizontalRule(trimmed) {
                flush()
                continue
            }
            if let content = listItemContent(line) {
                flush()
                startLine = lineNo
                lines = [content]
            } else if lines.isEmpty {
                startLine = lineNo
                lines = [trimmed]
            } else {
                lines.append(trimmed)
            }
        }
        flush()
        return entries
    }

    private static func isHeading(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("#") else { return false }
        let rest = trimmed.drop(while: { $0 == "#" })
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3, let c = trimmed.first, "-*_=".contains(c) else { return false }
        return trimmed.allSatisfy { $0 == c }
    }

    /// Returns the item text when `line` starts with a list marker, else nil.
    static func listItemContent(_ line: String) -> String? {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" { idx = line.index(after: idx) }
        guard idx < line.endIndex else { return nil }

        var after = idx
        let c = line[idx]
        if c == "-" || c == "*" || c == "+" {
            after = line.index(after: idx)
        } else if c.isASCII, c.isNumber {
            var d = idx
            while d < line.endIndex, line[d].isASCII, line[d].isNumber { d = line.index(after: d) }
            guard d < line.endIndex, line[d] == "." || line[d] == ")" else { return nil }
            after = line.index(after: d)
        } else {
            return nil
        }
        guard after < line.endIndex, line[after] == " " || line[after] == "\t" else {
            // A bare marker ("-") starts an empty item whose text follows on later lines.
            return after == line.endIndex ? "" : nil
        }
        var content = String(line[after...]).trimmingCharacters(in: .whitespaces)
        for box in ["[ ]", "[x]", "[X]"] where content.hasPrefix(box) {
            content = String(content.dropFirst(box.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return content
    }
}
