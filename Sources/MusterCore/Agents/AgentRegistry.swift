import Foundation

public struct AgentLocation: Sendable, Equatable {
    public let homeRelative: String
    public var environmentKey: String? = nil
    public var environmentRelative: String = ""

    public func resolve(home: String, environment: [String: String]) -> String {
        if let key = environmentKey, let value = environment[key], !value.isEmpty {
            let base = value == "~" ? home : (value.hasPrefix("~/") ? home + String(value.dropFirst()) : value)
            return environmentRelative.isEmpty ? base : base + "/" + environmentRelative
        }
        return home + "/" + homeRelative
    }
}

public struct AgentDescriptor: Identifiable, Sendable {
    public let id: String
    public let name: String
    public var kind: AgentKind? = nil
    public var executables: [String] = []
    public var nodePackages: [String] = []
    public var transcript: AgentLocation? = nil
    public var transcriptDepth = 2
    public var resumeArguments: [String] = []
    public var rules: [AgentLocation] = []
    public var configuration: AgentLocation? = nil
    public var configurationOrder = Int.max
    public var editableConfiguration = false
    public var jsonConfiguration = false
    public var providerKey = "model_provider"
    public var modelKey = "model"
    public var skills: AgentSkillCapability? = nil
    public var installationExecutables: [String] = []
    public var applications: [AgentApplication] = []

    public var tracksProcesses: Bool { kind != nil && !executables.isEmpty }
    public var tracksActivity: Bool { transcript != nil }
    public var syncsRules: Bool { !rules.isEmpty }
    public var resumesSessions: Bool { !resumeArguments.isEmpty }
}

/// Each integration declares its capabilities and paths here. Consumers do not invent support.
public enum AgentRegistry {
    private static func path(_ fallback: String, _ key: String? = nil, _ suffix: String = "") -> AgentLocation {
        AgentLocation(homeRelative: fallback, environmentKey: key, environmentRelative: suffix)
    }

    public static let all: [AgentDescriptor] = [
        AgentDescriptor(id: "claude", name: "Claude Code", kind: .claude, executables: ["claude"], nodePackages: ["/claude-code/"],
            transcript: path(".claude/projects", "CLAUDE_CONFIG_DIR", "projects"), resumeArguments: ["claude", "--resume"],
            rules: [path(".claude/CLAUDE.md", "CLAUDE_CONFIG_DIR", "CLAUDE.md"), path(".claude/AGENTS.md", "CLAUDE_CONFIG_DIR", "AGENTS.md")],
            configuration: path(".claude/settings.json", "CLAUDE_CONFIG_DIR", "settings.json"), configurationOrder: 2,
            skills: .init(directory: path(".claude/skills", "CLAUDE_CONFIG_DIR", "skills"))),
        AgentDescriptor(id: "codex", name: "Codex", kind: .codex, executables: ["codex"], nodePackages: ["/@openai/codex/"],
            transcript: path(".codex/sessions", "CODEX_HOME", "sessions"), transcriptDepth: 4, resumeArguments: ["codex", "resume"],
            rules: [path(".codex/AGENTS.override.md", "CODEX_HOME", "AGENTS.override.md"), path(".codex/AGENTS.md", "CODEX_HOME", "AGENTS.md")],
            configuration: path(".codex/config.toml", "CODEX_HOME", "config.toml"), configurationOrder: 0, editableConfiguration: true,
            skills: .init(directory: path(".agents/skills"),
                          additionalDiscovery: [path(".codex/skills", "CODEX_HOME", "skills")], sharedReaders: ["codex", "pi"]),
            applications: [.init(relativePath: "Codex.app"),
                           .init(relativePath: "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app", bundleIdentifier: "com.openai.codex.cli")]),
        AgentDescriptor(id: "pi", name: "Pi", kind: .pi, executables: ["pi"], nodePackages: ["/pi-coding-agent/"],
            transcript: path(".pi/agent/sessions", "PI_CODING_AGENT_DIR", "sessions"), resumeArguments: ["pi", "--session"],
            rules: [path(".pi/agent/AGENTS.override.md", "PI_CODING_AGENT_DIR", "AGENTS.override.md"), path(".pi/agent/AGENTS.md", "PI_CODING_AGENT_DIR", "AGENTS.md"), path(".pi/agent/CLAUDE.md", "PI_CODING_AGENT_DIR", "CLAUDE.md")],
            configuration: path(".pi/agent/settings.json", "PI_CODING_AGENT_DIR", "settings.json"), configurationOrder: 1,
            editableConfiguration: true, jsonConfiguration: true, providerKey: "defaultProvider", modelKey: "defaultModel",
            skills: .init(directory: path(".pi/agent/skills", "PI_CODING_AGENT_DIR", "skills"), additionalDiscovery: [path(".agents/skills")])),
        AgentDescriptor(id: "dsh", name: "DeepSeek Harness", kind: .dsh, executables: ["dsh"],
            rules: [path(".dsh/AGENTS.md", "DSH_HOME", "AGENTS.md")]),
        AgentDescriptor(id: "gemini", name: "Gemini CLI", kind: .gemini, executables: ["gemini"], nodePackages: ["/gemini-cli/"],
            rules: [path(".gemini/GEMINI.md")]),
        AgentDescriptor(id: "cursor", name: "Cursor", kind: .cursor, executables: ["cursor-agent"],
            rules: [path(".cursorrules")], configuration: path("Library/Application Support/Cursor/User/settings.json"), configurationOrder: 4,
            applications: [.init(relativePath: "Cursor.app")]),
        AgentDescriptor(id: "opencode", name: "OpenCode", kind: .opencode, executables: ["opencode"]),
        AgentDescriptor(id: "hermes", name: "Hermes", configuration: path(".hermes/config.yaml", "HERMES_HOME", "config.yaml"), configurationOrder: 3,
            installationExecutables: ["hermes"]),
        AgentDescriptor(id: "warp", name: "Warp", configuration: path(".warp/settings.toml"), configurationOrder: 5,
            applications: [.init(relativePath: "Warp.app", bundleIdentifier: "dev.warp.Warp-Stable")]),
        AgentDescriptor(id: "magpie", name: "Magpie", configuration: path(".config/magpie/settings.json"), configurationOrder: 6,
            installationExecutables: ["magpie"], applications: [.init(relativePath: "magpie.app", bundleIdentifier: "com.yetone.magpie")]),
    ]

    public static func agent(_ id: String) -> AgentDescriptor? { all.first { $0.id == id } }

    public static func skillTargets(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [SkillTarget] {
        all.compactMap { agent in
            guard let capability = agent.skills else { return nil }
            return SkillTarget(id: agent.id, name: agent.name, directory: capability.directory.resolve(home: home, environment: environment),
                discoveryDirectories: capability.additionalDiscovery.map { $0.resolve(home: home, environment: environment) },
                sharedReaders: capability.sharedReaders)
        }
    }

    public static func kind(forArgs args: [String]) -> AgentKind? {
        guard let executable = args.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        if let direct = all.first(where: { $0.executables.contains(executable) }) { return direct.kind }
        guard executable == "node", args.count > 1 else { return nil }
        return all.first { agent in agent.nodePackages.contains { args[1].contains($0) } }?.kind
    }

    public static func transcriptScanners(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment,
                                         retention: TimeInterval = SessionPolicy.defaultRetention) -> [TranscriptScanner] {
        all.compactMap { agent in
            guard let kind = agent.kind, let location = agent.transcript else { return nil }
            return TranscriptScanner(agent: kind, depth: agent.transcriptDepth,
                projectsRoot: URL(fileURLWithPath: location.resolve(home: home, environment: environment)), retention: retention)
        }
    }
}
