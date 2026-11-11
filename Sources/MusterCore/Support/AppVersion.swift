import Foundation

/// 语义化版本号，只用于「有没有新版本」的比较。
/// 容忍前缀 `v`、1–3 个数字段（缺的段按 0）；`-prerelease` / `+build` 后缀会被忽略，不参与排序。
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// 无法解析（空串、非数字段、超过 3 段）时返回 nil
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = String(text[..<cut]) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        self.init(major: numbers[0], minor: numbers.count > 1 ? numbers[1] : 0, patch: numbers.count > 2 ? numbers[2] : 0)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    /// `latest` 严格新于 `current`；任一方解析失败都视为「没有更新」
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let latest = AppVersion(latest), let current = AppVersion(current) else { return false }
        return latest > current
    }
}
