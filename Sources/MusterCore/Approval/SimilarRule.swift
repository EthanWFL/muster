import Foundation
import MusterProtocol

public struct SimilarRuleOptions: Sendable, Equatable {
    /// 前缀最多取几个 token
    public var prefixLength: Int
    /// 默认 false：高危命令不提供「允许同类」
    public var allowHighRisk: Bool

    public init(prefixLength: Int = 2, allowHighRisk: Bool = false) {
        self.prefixLength = max(1, prefixLength)
        self.allowHighRisk = allowHighRisk
    }
}

/// 「允许同类（本会话）」规则：session + 工具名 + 命令前缀。
/// 非 shell 工具（Edit/Write 等）前缀为空，按工具名匹配。
public struct SimilarRule: Sendable, Hashable {
    public let sessionID: String
    /// 小写
    public let tool: String
    /// 字面 token（不做 basename 归一，`/tmp/x/ls` 不会匹配 `ls` 的规则）
    public let prefix: [String]
    /// 创建时被批准的风险上限；之后的请求风险高于它就不匹配
    public let maxRisk: Risk

    public init(sessionID: String, tool: String, prefix: [String], maxRisk: Risk) {
        self.sessionID = sessionID
        self.tool = tool.lowercased()
        self.prefix = prefix
        self.maxRisk = maxRisk
    }
}

/// 纯内存、值类型；`ApprovalStore` 在锁内持有它。session 结束时调用 `removeAll(session:)`。
public struct SimilarRuleBook: Sendable {
    public private(set) var rules: [SimilarRule] = []
    public var options: SimilarRuleOptions
    public let classifier: RiskClassifier

    public init(options: SimilarRuleOptions = SimilarRuleOptions(), classifier: RiskClassifier = RiskClassifier()) {
        self.options = options
        self.classifier = classifier
    }

    // MARK: Creation

    /// 不合格返回 nil：高危（除非 `allowHighRisk`）、代码执行类前缀（`bash`、`env`、`python`…）、
    /// 前缀含变量/通配/替换、命令取不到文本。
    public func makeRule(sessionID: String, tool: String, input: [String: JSONValue], risk: Risk) -> SimilarRule? {
        if risk == .high && !options.allowHighRisk { return nil }
        let name = tool.lowercased()
        guard RiskTables.shellTools.contains(name) else {
            return SimilarRule(sessionID: sessionID, tool: name, prefix: [], maxRisk: risk)
        }
        guard let command = RiskClassifier.commandText(from: input),
              let first = ShellParser.parse(command).segments.first,
              let prefix = Self.commandPrefix(of: first.tokens, length: options.prefixLength)
        else { return nil }
        // 上限取第一段整体的风险：用户批准的是「这类命令」，不是串联里的别的段
        let segmentRisk = classifier.assessCommand(first.tokens.map(RiskClassifier.shellQuote).joined(separator: " ")).risk
        let maxRisk = min(segmentRisk, risk)
        if maxRisk == .high && !options.allowHighRisk { return nil }
        return SimilarRule(sessionID: sessionID, tool: name, prefix: prefix, maxRisk: maxRisk)
    }

    /// 取到第一个选项或 `length` 个 token 为止。不合格返回 nil。
    static func commandPrefix(of tokens: [String], length: Int) -> [String]? {
        guard let first = tokens.first, !first.hasPrefix("-"), !RiskClassifier.isAssignment(first) else { return nil }
        if RiskTables.codeRunners.contains(RiskClassifier.executableName(first)) { return nil }
        var out: [String] = []
        for t in tokens.prefix(max(1, length)) {
            if t.hasPrefix("-") { break }
            guard !t.contains(where: { "$`*?~{}\\".contains($0) }) else {
                if out.isEmpty { return nil }
                break
            }
            out.append(t)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: Matching

    public mutating func add(_ rule: SimilarRule) {
        if !rules.contains(rule) { rules.append(rule) }
    }

    public mutating func removeAll(session sessionID: String) {
        rules.removeAll { $0.sessionID == sessionID }
    }

    /// 命中返回规则。shell 命令必须是**单条简单命令**（无串联/管道/替换/重定向），
    /// 否则 `git status; rm -rf ~` 会借 `git status` 的规则混过去。
    public func match(sessionID: String, tool: String, input: [String: JSONValue], risk: Risk) -> SimilarRule? {
        if risk == .high && !options.allowHighRisk { return nil }
        let name = tool.lowercased()
        let candidates = rules.filter { $0.sessionID == sessionID && $0.tool == name && risk <= $0.maxRisk }
        guard !candidates.isEmpty else { return nil }
        guard RiskTables.shellTools.contains(name) else {
            return candidates.first { $0.prefix.isEmpty }
        }
        guard let command = RiskClassifier.commandText(from: input) else { return nil }
        let parsed = ShellParser.parse(command)
        guard parsed.isSimple, let tokens = parsed.segments.first?.tokens else { return nil }
        if tokens.contains(where: RiskTables.codeCarryingOptions.contains) { return nil }
        return candidates.first { !$0.prefix.isEmpty && tokens.starts(with: $0.prefix) }
    }
}
