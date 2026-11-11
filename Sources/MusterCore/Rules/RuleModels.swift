import Foundation

/// The four rule-file flavours F5 looks at.
public enum RuleFileKind: String, Sendable, CaseIterable, Equatable {
    case claudeMd
    case agentsMd
    case cursorrules
    case copilotInstructions

    /// `parentName` is only used for `copilot-instructions.md`, which counts only inside `.github`.
    public static func kind(forFileName name: String, parentName: String) -> RuleFileKind? {
        switch name {
        case "CLAUDE.md": return .claudeMd
        case "AGENTS.md": return .agentsMd
        case ".cursorrules": return .cursorrules
        case "copilot-instructions.md": return parentName == ".github" ? .copilotInstructions : nil
        default: return nil
        }
    }
}

/// An entry as produced by the parser (no file context yet). This is what the mtime cache stores.
public struct ParsedRuleEntry: Sendable, Equatable, Hashable {
    /// 1-based line of the first line of the entry.
    public var line: Int
    /// Entry text. List marker removed; continuation lines joined with "\n" (one "\n" = one source line).
    public var text: String

    public init(line: Int, text: String) {
        self.line = line
        self.text = text
    }
}

public struct RuleEntry: Sendable, Equatable, Hashable {
    public var filePath: String
    public var repoRoot: String
    public var kind: RuleFileKind
    public var line: Int
    public var text: String

    public init(filePath: String, repoRoot: String, kind: RuleFileKind, line: Int, text: String) {
        self.filePath = filePath
        self.repoRoot = repoRoot
        self.kind = kind
        self.line = line
        self.text = text
    }

    /// `path:line`, the form the UI shows and copies.
    public var location: String { "\(filePath):\(line)" }
}

public struct RuleFile: Sendable, Equatable {
    public var path: String
    public var kind: RuleFileKind
    public var repoRoot: String
    public var modificationDate: Date
    public var size: Int
    public var entries: [RuleEntry]
}

public struct DuplicateGroup: Sendable, Equatable {
    /// Two or more entries, sorted by path then line.
    public var entries: [RuleEntry]
    /// Lowest pairwise Jaccard score among the pairs that linked this group.
    public var similarity: Double
}

public enum ReferenceKind: String, Sendable, Equatable {
    case path
    case command
}

public struct StaleReference: Sendable, Equatable {
    public var entry: RuleEntry
    /// The backtick content, e.g. `Scripts/build.sh`.
    public var reference: String
    public var kind: ReferenceKind
    /// Source line of the reference itself (entry.line plus offset inside a multi-line entry).
    public var line: Int
    /// For paths: every absolute location that was tried.
    public var checkedPaths: [String]

    public var location: String { "\(entry.filePath):\(line)" }
}

public struct RuleScanStats: Sendable, Equatable {
    public var filesFound = 0
    /// Files whose content was read and parsed during this scan (cache misses).
    public var filesParsed = 0
    /// Files served from the mtime cache.
    public var filesFromCache = 0
    public var reparsedPaths: [String] = []
    public var entryCount = 0
    public var duration: TimeInterval = 0
}

public struct RuleScanProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case discovering, parsing, analyzing, done }
    public var phase: Phase
    public var completed: Int
    public var total: Int
    public var currentPath: String?
}

public struct RuleReport: Sendable {
    public var root: String
    public var files: [RuleFile]
    public var duplicates: [DuplicateGroup]
    public var staleReferences: [StaleReference]
    public var contradictions: [Contradiction]
    public var stats: RuleScanStats
}
