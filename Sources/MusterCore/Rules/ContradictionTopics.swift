import Foundation

/// One choice inside a topic, e.g. "pnpm" in the package-manager topic.
public struct ContradictionOption: Sendable, Equatable, Codable {
    public var name: String
    /// Lowercase words or phrases that mention the option. Phrases are split like prose (spaces),
    /// CJK aliases match character by character.
    public var aliases: [String]

    public init(name: String, aliases: [String]) {
        self.name = name
        self.aliases = aliases
    }
}

/// A whitelisted topic. Only topics in this table are ever checked for contradictions.
public struct ContradictionTopic: Sendable, Equatable, Codable {
    public var id: String
    public var title: String
    public var options: [ContradictionOption]

    public init(id: String, title: String, options: [ContradictionOption]) {
        self.id = id
        self.title = title
        self.options = options
    }

    /// Loads a topic table from JSON (an array of topics), so users can extend the whitelist.
    public static func decode(json: Data) throws -> [ContradictionTopic] {
        try JSONDecoder().decode([ContradictionTopic].self, from: json)
    }

    public static let defaults: [ContradictionTopic] = [
        ContradictionTopic(id: "js-package-manager", title: "JavaScript package manager", options: [
            ContradictionOption(name: "pnpm", aliases: ["pnpm"]),
            ContradictionOption(name: "npm", aliases: ["npm"]),
            ContradictionOption(name: "yarn", aliases: ["yarn"]),
            ContradictionOption(name: "bun", aliases: ["bun"]),
        ]),
        ContradictionTopic(id: "python-package-manager", title: "Python package manager", options: [
            ContradictionOption(name: "pip", aliases: ["pip", "pip3"]),
            ContradictionOption(name: "poetry", aliases: ["poetry"]),
            ContradictionOption(name: "uv", aliases: ["uv"]),
            ContradictionOption(name: "conda", aliases: ["conda"]),
        ]),
        ContradictionTopic(id: "indentation", title: "Indentation", options: [
            ContradictionOption(name: "tabs", aliases: ["tab", "tabs", "制表符"]),
            ContradictionOption(name: "spaces", aliases: ["space", "spaces", "空格"]),
        ]),
        ContradictionTopic(id: "quote-style", title: "Quote style", options: [
            ContradictionOption(name: "single quotes", aliases: ["single quote", "single quotes", "单引号"]),
            ContradictionOption(name: "double quotes", aliases: ["double quote", "double quotes", "双引号"]),
        ]),
    ]
}

/// Words that turn a mention of an option into a stance. Data, so it can be tuned or translated.
/// "Before" cues are looked for in a short window ahead of the mention, "after" cues behind it.
/// The cue closest to the mention decides. A negator directly in front of a require cue flips it
/// ("do not use npm", "禁止使用 npm"). Windows end at clause separators (comma, period, newline...).
public struct DirectiveCues: Sendable, Equatable, Codable {
    public var requireBefore: [String]
    public var forbidBefore: [String]
    public var requireAfter: [String]
    public var forbidAfter: [String]
    /// Words that flip a require cue sitting right behind them.
    public var negators: [String]

    public init(
        requireBefore: [String], forbidBefore: [String], requireAfter: [String], forbidAfter: [String],
        negators: [String]
    ) {
        self.requireBefore = requireBefore
        self.forbidBefore = forbidBefore
        self.requireAfter = requireAfter
        self.forbidAfter = forbidAfter
        self.negators = negators
    }

    public static let `default` = DirectiveCues(
        requireBefore: [
            "use", "uses", "using", "must", "always", "prefer", "preferred", "only", "require", "required",
            "requires", "need", "needs",
            "必须", "务必", "一律", "只能", "统一", "使用", "用", "须", "需要",
        ],
        forbidBefore: [
            "not", "never", "avoid", "forbid", "forbidden", "prohibit", "prohibited", "ban", "banned",
            "don't", "dont", "doesn't", "cannot", "can't", "shouldn't", "mustn't", "instead", "over", "than",
            "without", "disallow", "disallowed",
            "禁止", "严禁", "不要", "不得", "不许", "不准", "不能", "不可", "勿", "别用", "避免", "不用",
            "不使用", "而不是", "而非",
        ],
        requireAfter: ["required", "mandatory", "必须"],
        forbidAfter: ["forbidden", "prohibited", "banned", "disallowed", "not allowed", "禁止", "不允许"],
        negators: [
            "not", "never", "don't", "dont", "doesn't", "cannot", "can't", "shouldn't", "mustn't", "no",
            "禁止", "严禁", "不要", "不得", "不许", "不准", "不能", "不可", "勿", "别", "不",
        ]
    )
}

public enum DirectiveStance: String, Sendable, Equatable, Hashable, Codable {
    case require
    case forbid
}

/// All entries that take the same stance on the same option.
public struct ContradictionPosition: Sendable, Equatable {
    public var option: String
    public var stance: DirectiveStance
    /// Sorted by path then line.
    public var entries: [RuleEntry]
}

public struct Contradiction: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// One place requires an option, another forbids it.
        case requireVersusForbid
        /// Two places each require a different option of the same topic.
        case conflictingChoice
    }

    public var topicID: String
    public var topicTitle: String
    public var kind: Kind
    /// Only the positions that take part in a conflict.
    public var positions: [ContradictionPosition]
    public var summary: String
}
