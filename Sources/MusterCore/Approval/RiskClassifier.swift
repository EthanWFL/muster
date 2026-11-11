import Foundation
import MusterProtocol

public struct RiskAssessment: Sendable, Equatable {
    public var risk: Risk
    /// 命中的规则名，便于 UI 展示和测试断言
    public var reason: String

    public init(_ risk: Risk, _ reason: String) {
        self.risk = risk
        self.reason = reason
    }
}

/// 规则表驱动的风险分类器（规则见 `RiskTables`）。
/// 原则：判断不了就是中危，绝不是低危；串联取各段最高风险。
public struct RiskClassifier: Sendable {
    public let commandRules: [CommandRule]
    public let toolRules: [ToolRule]

    public init(
        commandRules: [CommandRule] = RiskTables.commandRules,
        toolRules: [ToolRule] = RiskTables.toolRules
    ) {
        self.commandRules = commandRules
        self.toolRules = toolRules
    }

    public func classify(tool: String, input: [String: JSONValue]) -> Risk {
        assess(tool: tool, input: input).risk
    }

    public func assess(tool: String, input: [String: JSONValue]) -> RiskAssessment {
        let name = tool.lowercased()
        if RiskTables.shellTools.contains(name) {
            guard let command = Self.commandText(from: input) else {
                return RiskAssessment(.medium, "shell tool without command")
            }
            return assessCommand(command)
        }
        if let rule = toolRules.first(where: { $0.tools.contains(name) }) {
            return RiskAssessment(rule.risk, rule.name)
        }
        return RiskAssessment(.medium, "unknown tool")
    }

    public func assessCommand(_ command: String, depth: Int = 0) -> RiskAssessment {
        if command.allSatisfy(\.isWhitespace) { return RiskAssessment(.medium, "empty command") }
        if depth > ShellParser.maxDepth { return RiskAssessment(.high, "shell nesting too deep") }
        let parsed = ShellParser.parse(command)
        if parsed.tooDeep { return RiskAssessment(.high, "substitution nesting too deep") }
        guard !parsed.segments.isEmpty else { return RiskAssessment(.medium, "no executable") }

        var best = RiskAssessment(.low, "")
        var seen = false
        for segment in parsed.segments {
            let a = assessSegment(segment, depth: depth)
            if !seen || a.risk > best.risk { best = a; seen = true }
            if best.risk == .high { return best }
        }
        if parsed.unbalanced, best.risk < .medium {
            best = RiskAssessment(.medium, "unbalanced quote or substitution")
        }
        if parsed.hasRedirect, best.risk < .medium {
            best = RiskAssessment(.medium, "output redirection")
        }
        return best
    }

    /// `command` 字符串，或 Codex 风格的 argv 数组（逐项加引号后拼成一条命令，保持语义）
    static func commandText(from input: [String: JSONValue]) -> String? {
        for key in ["command", "cmd"] {
            switch input[key] {
            case .string(let s)?:
                return s.allSatisfy(\.isWhitespace) ? nil : s
            case .array(let items)?:
                let parts = items.compactMap(\.stringValue)
                if !parts.isEmpty, parts.count == items.count { return parts.map(shellQuote).joined(separator: " ") }
                return nil
            default:
                continue
            }
        }
        return nil
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
