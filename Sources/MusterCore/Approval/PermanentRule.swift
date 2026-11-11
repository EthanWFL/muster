import Foundation
import MusterProtocol

/// A permanent allow rule read from Claude's `permissions.allow`.
///
/// Only exact `Bash(<command>)` rules are understood. Prefix rules (`Bash(git:*)`) and
/// wildcard/path rules are ignored: a hook decision must never be wider than what the user
/// actually wrote in the settings file.
public struct PermanentRule: Hashable, Sendable {
    /// Lowercased tool name. Only `bash` is supported today.
    public let tool: String
    /// Exact command text, as written in the rule.
    public let command: String

    public init(tool: String, command: String) {
        self.tool = tool.lowercased()
        self.command = command
    }

    /// The line as it appears in `permissions.allow`.
    public var text: String { "\(displayTool)(\(command))" }

    private var displayTool: String { tool == "bash" ? "Bash" : tool }

    /// Parses one `permissions.allow` entry. Returns nil for anything we do not fully understand.
    public static func parse(_ text: String) -> PermanentRule? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return nil }
        let name = String(trimmed[..<open])
        let command = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        guard name.lowercased() == "bash" else { return nil }
        return make(command: command)
    }

    /// Builds a rule for a simple Bash command, or nil when the command cannot be represented
    /// safely as an exact rule.
    public static func make(command: String) -> PermanentRule? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return nil }
        // `*` turns the rule into a prefix match; the rest can change meaning inside a rule or shell.
        guard !cmd.contains(where: { "()*$`\\\n\r".contains($0) }) else { return nil }
        guard ShellParser.parse(cmd).isSimple else { return nil }
        return PermanentRule(tool: "bash", command: cmd)
    }

    /// A rule for a tool call, if that call is eligible for "always allow".
    public static func make(for call: ToolCall) -> PermanentRule? {
        guard call.tool.lowercased() == "bash",
              let command = RiskClassifier.commandText(from: call.input) else { return nil }
        return make(command: command)
    }

    public func matches(tool: String, input: [String: JSONValue]) -> Bool {
        guard tool.lowercased() == self.tool,
              let candidate = RiskClassifier.commandText(from: input) else { return false }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines) == command
    }
}
