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
        AgentRegistry.all.filter(\.syncsRules).map { agent in
            let candidates = agent.rules.map { $0.resolve(home: home, environment: environment) }
            let path = candidates.first(where: exists) ?? candidates[0]
            let directory = (path as NSString).deletingLastPathComponent
            // A user's home directory alone is not evidence that Cursor is installed.
            let installed = exists(path) || (directory != home && exists(directory))
            return InstructionTarget(id: agent.id, name: agent.name, path: path, installed: installed,
                redirectedFrom: path.hasSuffix("AGENTS.override.md") ? directory + "/AGENTS.md" : nil)
        }
    }
}
