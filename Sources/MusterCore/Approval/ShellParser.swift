import Foundation

/// 分隔两个命令段的操作符。`substitution` 表示 `$(...)`/反引号/进程替换里的内层命令。
enum ShellOperator: String, Sendable, Equatable {
    case semicolon, and, or, pipe, background, newline, group, substitution
}

struct ShellSegment: Equatable, Sendable {
    /// 去引号、去反斜杠后的 token
    var tokens: [String]
    /// 紧挨在该段之前的操作符；首段为 nil
    var op: ShellOperator?
}

struct ParsedCommand: Equatable, Sendable {
    /// 顶层各段在前（顺序即书写顺序），内层替换命令追加在后
    var segments: [ShellSegment] = []
    var hasSubstitution = false
    var hasRedirect = false
    /// 替换嵌套超过上限，调用方应按最高风险处理
    var tooDeep = false
    /// 引号、`$(`、反引号未闭合或以反斜杠结尾：无法确定真实语义，调用方不得判为低危
    var unbalanced = false

    /// 单条简单命令：无串联、无替换、无重定向
    var isSimple: Bool { segments.count == 1 && !hasSubstitution && !hasRedirect && !tooDeep && !unbalanced }
}

/// 面向风险判断的保守 shell 切分器：宁可多切出命令段，也不漏掉。
/// 不做完整 POSIX 解析，不展开变量/别名/通配符。
enum ShellParser {
    static let maxDepth = 6

    static func parse(_ input: String) -> ParsedCommand {
        parse(Array(input), depth: 0, firstOp: nil)
    }

    private static func parse(_ c: [Character], depth: Int, firstOp: ShellOperator?) -> ParsedCommand {
        var result = ParsedCommand()
        var subs: [ParsedCommand] = []
        var tokens: [String] = []
        var word = ""
        var hasWord = false
        var op: ShellOperator? = firstOp
        var i = 0
        var inSingle = false
        var inDouble = false

        func endWord() {
            if hasWord { tokens.append(word) }
            word = ""
            hasWord = false
        }
        func endSegment(_ next: ShellOperator) {
            endWord()
            if !tokens.isEmpty {
                result.segments.append(ShellSegment(tokens: tokens, op: op))
                op = next
            } else if next != .newline || op == nil {
                // 空段后的换行不应覆盖前面的 `|`/`&&`
                op = next
            }
            tokens = []
        }
        func substitute(_ inner: String) {
            result.hasSubstitution = true
            if depth >= maxDepth {
                result.tooDeep = true
            } else {
                subs.append(parse(Array(inner), depth: depth + 1, firstOp: .substitution))
            }
            word += "$()"
            hasWord = true
        }
        func peek(_ offset: Int = 1) -> Character? {
            i + offset < c.count ? c[i + offset] : nil
        }

        while i < c.count {
            let ch = c[i]
            if inSingle {
                if ch == "'" { inSingle = false } else { word.append(ch) }
                i += 1
                continue
            }
            if ch == "\\" {
                if let n = peek() {
                    if n != "\n" { word.append(n); hasWord = true }
                    i += 2
                } else {
                    result.unbalanced = true
                    i += 1
                }
                continue
            }
            if ch == "'" && !inDouble { inSingle = true; hasWord = true; i += 1; continue }
            if ch == "\"" { inDouble.toggle(); hasWord = true; i += 1; continue }
            if ch == "`" {
                let (inner, next, closed) = scanBacktick(c, from: i + 1)
                if !closed { result.unbalanced = true }
                substitute(inner)
                i = next
                continue
            }
            if ch == "$", peek() == "(" {
                let (inner, next, closed) = scanParen(c, from: i + 2)
                if !closed { result.unbalanced = true }
                substitute(inner)
                i = next
                continue
            }
            if inDouble { word.append(ch); hasWord = true; i += 1; continue }

            switch ch {
            case " ", "\t":
                endWord()
            case "\n":
                endSegment(.newline)
            case ";":
                endSegment(.semicolon)
            case "|":
                if peek() == "|" { i += 1; endSegment(.or) }
                else { if peek() == "&" { i += 1 }; endSegment(.pipe) }
            case "&":
                if peek() == "&" { i += 1; endSegment(.and) }
                else if peek() == ">" { endWord(); result.hasRedirect = true }
                else { endSegment(.background) }
            case "(", ")":
                endSegment(.group)
            case ">", "<":
                if peek() == "(" {
                    let (inner, next, closed) = scanParen(c, from: i + 2)
                    if !closed { result.unbalanced = true }
                    substitute(inner)
                    i = next
                    continue
                }
                if ch == ">" {
                    if hasWord && word.allSatisfy({ $0.isASCII && $0.isNumber }) {
                        word = ""
                        hasWord = false
                    } else {
                        endWord()
                    }
                    result.hasRedirect = true
                } else {
                    endWord()
                }
                while let n = peek(), n == "<" || n == ">" || n == "|" || n == "&" { i += 1 }
            default:
                word.append(ch)
                hasWord = true
            }
            i += 1
        }
        if inSingle || inDouble { result.unbalanced = true }
        endSegment(.newline)

        for s in subs {
            result.segments += s.segments
            result.hasSubstitution = result.hasSubstitution || s.hasSubstitution
            result.hasRedirect = result.hasRedirect || s.hasRedirect
            result.tooDeep = result.tooDeep || s.tooDeep
            result.unbalanced = result.unbalanced || s.unbalanced
        }
        return result
    }

    /// `start` 为 `$(` 之后的下标；返回内层文本与闭合括号之后的下标。括号未闭合则取到末尾。
    private static func scanParen(_ c: [Character], from start: Int) -> (String, Int, Bool) {
        var depth = 1
        var i = start
        var inSingle = false
        var inDouble = false
        while i < c.count {
            let ch = c[i]
            if inSingle { if ch == "'" { inSingle = false }; i += 1; continue }
            if ch == "\\" { i += 2; continue }
            if ch == "'" && !inDouble { inSingle = true }
            else if ch == "\"" { inDouble.toggle() }
            else if !inDouble && ch == "(" { depth += 1 }
            else if !inDouble && ch == ")" {
                depth -= 1
                if depth == 0 { return (String(c[start..<i]), i + 1, true) }
            }
            i += 1
        }
        return (String(c[min(start, c.count)...]), c.count, false)
    }

    private static func scanBacktick(_ c: [Character], from start: Int) -> (String, Int, Bool) {
        var i = start
        while i < c.count {
            if c[i] == "\\" { i += 2; continue }
            if c[i] == "`" { return (String(c[start..<i]), i + 1, true) }
            i += 1
        }
        return (String(c[min(start, c.count)...]), c.count, false)
    }
}
