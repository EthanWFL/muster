import Foundation

/// Builds the text behind the "copy suggestion" button. These functions only return a String;
/// the UI puts it on the clipboard. Nothing here touches a rule file (R10).
public enum RuleSuggestion {
    public static func text(for group: DuplicateGroup) -> String {
        var lines = ["Duplicate rule (\(group.entries.count) places, similarity \(percent(group.similarity))):"]
        for e in group.entries { lines.append("- \(e.location): \(oneLine(e.text))") }
        if let keep = group.entries.first {
            lines.append("Suggestion: keep one copy (for example \(keep.location)) and delete the others, or move it to a shared parent folder.")
        }
        return lines.joined(separator: "\n")
    }

    public static func text(for ref: StaleReference) -> String {
        let what = ref.kind == .path ? "path" : "command"
        var lines = ["Stale \(what) reference at \(ref.location): `\(ref.reference)`"]
        lines.append("Rule: \(oneLine(ref.entry.text))")
        switch ref.kind {
        case .path:
            lines.append("Not found in: " + ref.checkedPaths.joined(separator: ", "))
            lines.append("Suggestion: update the path to the file's new location, or delete this rule if it no longer applies.")
        case .command:
            lines.append("Suggestion: install the tool, name the command that replaced it, or delete this rule if it no longer applies.")
        }
        return lines.joined(separator: "\n")
    }

    public static func text(for contradiction: Contradiction) -> String {
        var lines = ["Conflicting rules about \(contradiction.topicTitle): \(contradiction.summary)"]
        for p in contradiction.positions {
            for e in p.entries {
                lines.append("- [\(p.stance.rawValue) \(p.option)] \(e.location): \(oneLine(e.text))")
            }
        }
        lines.append("Suggestion: pick one convention and make every repo's rule file say the same thing.")
        return lines.joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
