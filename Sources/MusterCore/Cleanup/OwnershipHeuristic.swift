import Foundation

public enum TreeEvidence: Equatable, Sendable {
    case none
    /// 现在就在 session 进程树内
    case currentTree
    /// 曾经在树内、现已被 launchd 收养（孤儿）。计分等同树内，但执行层不承认它「在树内」
    case formerTree
}

public struct OwnershipScore: Equatable, Sendable {
    public let sessionID: String
    public let points: Int
    public let maxPoints: Int
    public let isUncertain: Bool
    public let reasons: [String]

    /// 0...1
    public var confidence: Double { maxPoints > 0 ? Double(points) / Double(maxPoints) : 0 }
}

public struct OwnershipHeuristic: Sendable {
    public let weights: OwnershipWeights

    public init(weights: OwnershipWeights = .default) {
        self.weights = weights
    }

    public func score(
        process: ProcessRecord, commandLine: String?, session: Session, tree: TreeEvidence
    ) -> OwnershipScore {
        var points = 0
        var reasons: [String] = []

        if tree != .none {
            points += weights.processTree
            reasons.append(tree == .currentTree ? "在 session 进程树内" : "曾在 session 进程树内")
        }
        if let cwd = process.cwd, Self.path(cwd, isInside: session.cwd) {
            points += weights.cwdPrefix
            reasons.append("cwd 位于 session 目录下")
        }
        if let start = process.startTime,
           start >= session.startedAt.addingTimeInterval(-weights.startTimeTolerance) {
            points += weights.startedAfterSession
            reasons.append("启动时间晚于 session")
        }
        if hasKeyword(commandLine: commandLine, name: process.name) {
            points += weights.commandKeyword
            reasons.append("命令行含 dev 工具关键词")
        }

        return OwnershipScore(
            sessionID: session.id, points: points, maxPoints: weights.maxPoints,
            isUncertain: points < weights.confidentThreshold, reasons: reasons)
    }

    /// 在所有 session 中取得分最高者；无进程记录返回 nil。
    public func bestOwner(
        pid: Int32, sessions: [Session], snapshot: ProcessSnapshot, formerlyOwnedBy: String? = nil
    ) -> OwnershipScore? {
        guard let record = snapshot.processes[pid] else { return nil }
        let commandLine = snapshot.commandLines[pid]
        var best: OwnershipScore?
        for session in sessions {
            var evidence: TreeEvidence = .none
            if snapshot.isInTree(of: session, pid: pid) {
                evidence = .currentTree
            } else if formerlyOwnedBy == session.id {
                evidence = .formerTree
            }
            let s = score(process: record, commandLine: commandLine, session: session, tree: evidence)
            if best == nil || s.points > best!.points { best = s }
        }
        return best
    }

    // MARK: - 信号

    /// 路径分量匹配：`/a/proj-x` 不算在 `/a/proj` 之下。根目录 `/` 不参与匹配。
    static func path(_ path: String, isInside root: String) -> Bool {
        let p = normalize(path)
        let r = normalize(root)
        guard r != "/", !r.isEmpty else { return false }
        return p == r || p.hasPrefix(r + "/")
    }

    private static func normalize(_ path: String) -> String {
        var s = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func hasKeyword(commandLine: String?, name: String?) -> Bool {
        let text = [commandLine, name].compactMap { $0 }.joined(separator: " ").lowercased()
        guard !text.isEmpty else { return false }
        let separators = CharacterSet(charactersIn: " \t/=:")
        let tokens = text.components(separatedBy: separators).filter { !$0.isEmpty }
        return tokens.contains { token in
            weights.keywords.contains { token == $0 || token.hasPrefix($0 + "-") }
        }
    }
}
