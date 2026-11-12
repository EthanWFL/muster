import Foundation

/// 一个能收共享指令的 agent，以及它读的那份**用户级**指令文件。
///
/// 只列用户级（`~/.claude/CLAUDE.md` 这类）；仓库里的 `AGENTS.md` 不在写入范围内。
public struct InstructionTarget: Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    /// 绝对路径，已按环境变量解析（`CLAUDE_CONFIG_DIR` 等）
    public var path: String
    /// 文件和它的目录都不在时，说明这台机器上没装这个 agent
    public var installed: Bool
    /// 有 `AGENTS.override.md` 时它比 `AGENTS.md` 优先，写进前者才生效；这里记着被取代的那个
    public var redirectedFrom: String?

    public init(id: String, name: String, path: String, installed: Bool, redirectedFrom: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.installed = installed
        self.redirectedFrom = redirectedFrom
    }

    /// `~/.claude/CLAUDE.md`
    public var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

public enum InstructionTargets {
    /// 探测本机的 agent 指令文件。`exists` 可注入，测试用临时目录。
    public static func detect(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [InstructionTarget] {
        func env(_ key: String) -> String? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return (value as NSString).expandingTildeInPath
        }

        let claudeDir = env("CLAUDE_CONFIG_DIR") ?? home + "/.claude"
        let codexDir = env("CODEX_HOME") ?? home + "/.codex"
        let piDir = env("PI_CODING_AGENT_DIR") ?? home + "/.pi/agent"
        let dshDir = env("DSH_HOME") ?? home + "/.dsh"

        // 每个 agent 按它自己找文件的顺序给候选，取已存在的那个，都没有就用第一个。
        // `AGENTS.override.md` 在 Codex 和 Pi 里优先级更高：写进 AGENTS.md 会被它盖住，所以先试它。
        let specs: [(id: String, name: String, candidates: [String])] = [
            ("claude", "Claude Code", [claudeDir + "/CLAUDE.md", claudeDir + "/AGENTS.md"]),
            ("codex", "Codex", [codexDir + "/AGENTS.override.md", codexDir + "/AGENTS.md"]),
            ("pi", "Pi", [piDir + "/AGENTS.override.md", piDir + "/AGENTS.md", piDir + "/CLAUDE.md"]),
            ("dsh", "DeepSeek Harness", [dshDir + "/AGENTS.md"]),
            ("gemini", "Gemini CLI", [home + "/.gemini/GEMINI.md"]),
            ("cursor", "Cursor", [home + "/.cursorrules"]),
        ]

        return specs.map { spec in
            let path = spec.candidates.first(where: exists) ?? spec.candidates[0]
            let dir = (path as NSString).deletingLastPathComponent
            let installed = exists(path) || exists(dir)
            let replaced = path.hasSuffix("AGENTS.override.md")
                ? dir + "/AGENTS.md"
                : nil
            return InstructionTarget(
                id: spec.id, name: spec.name, path: path, installed: installed,
                redirectedFrom: replaced)
        }
    }
}
