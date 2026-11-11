import MusterCore
import AppKit
import Foundation

struct RuleFinding: Identifiable {
    enum Kind: String { case duplicate = "Duplicate", brokenRef = "Broken ref", conflict = "Conflict" }

    let id = UUID()
    let kind: Kind
    let title: String
    /// 绝对路径加行号，如 `/Users/x/Code/a/CLAUDE.md:14`
    let locations: [String]
    /// 「复制建议」的文本；只进剪贴板，绝不写规则文件（R10）
    let suggestion: String
}

/// 「规则」页：跨仓库扫描 CLAUDE.md / AGENTS.md 等，结果只读。
@MainActor
final class RulesModel: ObservableObject {
    @Published private(set) var findings: [RuleFinding] = []
    @Published private(set) var stats: RuleScanStats?
    @Published private(set) var isScanning = false
    @Published private(set) var scannedFiles = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasScanned = false

    let scanner = RuleScanner()

    /// 面板第一次打开该页时才扫描，之后由用户点 Rescan 触发（R11：按 mtime 增量）
    func scanIfNeeded() {
        if !hasScanned { scan() }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        let scanner = self.scanner
        Task {
            do {
                let report = try await scanner.scan()
                findings = Self.findings(from: report)
                stats = report.stats
                scannedFiles = report.files.count
            } catch {
                errorMessage = "Scan failed: \(error)"
            }
            isScanning = false
            hasScanned = true
        }
    }

    func copy(_ finding: RuleFinding) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(finding.suggestion, forType: .string)
    }

    static func open(location: String) {
        // `path:line`：行号跳转没有通用方案，只打开文件
        let path = location.split(separator: ":", maxSplits: 1).first.map(String.init) ?? location
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private static func findings(from report: RuleReport) -> [RuleFinding] {
        var out: [RuleFinding] = []
        for group in report.duplicates {
            out.append(RuleFinding(
                kind: .duplicate, title: oneLine(group.entries.first?.text ?? ""),
                locations: group.entries.map(\.location), suggestion: RuleSuggestion.text(for: group)))
        }
        for ref in report.staleReferences {
            let what = ref.kind == .path ? "does not exist" : "not found on PATH"
            out.append(RuleFinding(
                kind: .brokenRef, title: "`\(ref.reference)` \(what)",
                locations: [ref.location], suggestion: RuleSuggestion.text(for: ref)))
        }
        for c in report.contradictions {
            out.append(RuleFinding(
                kind: .conflict, title: c.summary,
                locations: c.positions.flatMap { $0.entries.map(\.location) },
                suggestion: RuleSuggestion.text(for: c)))
        }
        return out
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
    }
}
