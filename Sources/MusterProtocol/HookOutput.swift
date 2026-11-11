import Foundation

/// hook 进程最终要做的事：写 stdout、写 stderr、以某个退出码结束。
public struct HookOutput: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    /// 无决策：无输出、exit 0，等同于没装本工具（R2，fail-safe）。
    public static let noDecision = HookOutput()

    /// decision -> (stdout, stderr, exit code) 的唯一映射点。
    /// `decision == nil` 表示连接失败、超时、回包非法等一切异常，一律按无决策处理。
    ///
    /// 语义已由 M0 实测确认（docs/M0-findings.md，Claude Code 2.1.292）：
    ///   - allow / allow_similar -> JSON `permissionDecision:"allow"`，exit 0，跳过原生确认
    ///   - deny -> JSON `permissionDecision:"deny"` + reason，exit 0；模型看到的正好是 reason 文本。
    ///     （exit 2 + stderr 也能阻止，但模型会看到 `PreToolUse:Bash hook error: [path]: <reason>` 前缀）
    ///   - no_decision -> 无输出 exit 0，回落到原生确认流程。**不能用 "ask"**：ask 会强制弹确认，
    ///     连本来自动放行的命令也会被拦。
    ///   - hook 超时/缺失/崩溃/exit 1 时 Claude 自己会回落到原生流程，所以任何失败都必须无输出 exit 0。
    public static func make(decision: WireDecision?, reason: String?) -> HookOutput {
        switch decision {
        case .allow?, .allowSimilar?:
            return json(permission: "allow", reason: nonEmpty(reason) ?? "Approved in Muster")
        case .deny?:
            return json(permission: "deny", reason: nonEmpty(reason) ?? "Denied via Muster")
        case .noDecision?, nil:
            return .noDecision
        }
    }

    static func json(permission: String, reason: String) -> HookOutput {
        let payload: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PreToolUse"),
                "permissionDecision": .string(permission),
                "permissionDecisionReason": .string(reason),
            ]),
        ])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(payload), let text = String(data: data, encoding: .utf8) else {
            // 编码失败不能变成拦截，也不能变成放行：无决策最安全
            return .noDecision
        }
        return HookOutput(stdout: text + "\n", stderr: "", exitCode: 0)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
