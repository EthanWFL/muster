import Foundation

/// Finds entries whose token sets have Jaccard similarity above `threshold`.
///
/// Avoids O(n^2) with two exact filters (no true match is lost):
/// 1. size bucket: J(A,B) <= min/max, so a candidate must have more than `threshold` times the tokens;
/// 2. prefix filter: tokens are ordered rarest-first and only the first `n - ceil(t*n) + 1` of each set
///    are indexed. Two sets with J >= t must share a token inside those prefixes.
public struct DuplicateDetector: Sendable {
    public var threshold: Double
    /// Entries with fewer tokens are ignored (too short to call a duplicate).
    public var minTokens: Int

    public init(threshold: Double = 0.8, minTokens: Int = 3) {
        self.threshold = threshold
        self.minTokens = minTokens
    }

    public func findDuplicates(in entries: [RuleEntry]) -> [DuplicateGroup] {
        struct Item { let index: Int; let tokens: Set<String>; var ordered: [String] = [] }

        var items: [Item] = []
        var freq: [String: Int] = [:]
        for (i, e) in entries.enumerated() {
            let t = RuleTextNormalizer.tokens(e.text)
            guard t.count >= minTokens else { continue }
            items.append(Item(index: i, tokens: t))
            for tok in t { freq[tok, default: 0] += 1 }
        }
        for i in items.indices {
            items[i].ordered = items[i].tokens.sorted {
                let (fa, fb) = (freq[$0] ?? 0, freq[$1] ?? 0)
                return fa != fb ? fa < fb : $0 < $1
            }
        }
        items.sort { $0.tokens.count != $1.tokens.count ? $0.tokens.count < $1.tokens.count : $0.index < $1.index }

        var postings: [String: [Int]] = [:]  // token -> positions in `items`
        var pairs: [(Int, Int, Double)] = []  // entry indices + score

        for (pos, item) in items.enumerated() {
            let n = item.tokens.count
            let need = Int((threshold * Double(n) - 1e-9).rounded(.up))
            let prefixLen = max(1, min(n, n - need + 1))
            let prefix = item.ordered.prefix(prefixLen)

            var seen = Set<Int>()
            for tok in prefix {
                for other in postings[tok] ?? [] where seen.insert(other).inserted {
                    let o = items[other]
                    guard Double(o.tokens.count) > threshold * Double(n) - 1e-9 else { continue }
                    let score = RuleTextNormalizer.jaccard(item.tokens, o.tokens)
                    if score > threshold { pairs.append((o.index, item.index, score)) }
                }
            }
            for tok in prefix { postings[tok, default: []].append(pos) }
        }
        return buildGroups(entries: entries, pairs: pairs)
    }

    private func buildGroups(entries: [RuleEntry], pairs: [(Int, Int, Double)]) -> [DuplicateGroup] {
        var parent = Array(0..<entries.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { (parent[c], c) = (r, parent[c]) }
            return r
        }
        for (a, b, _) in pairs { parent[find(a)] = find(b) }

        var members: [Int: Set<Int>] = [:]
        var minScore: [Int: Double] = [:]
        for (a, b, s) in pairs {
            let r = find(a)
            members[r, default: []].formUnion([a, b])
            minScore[r] = min(minScore[r] ?? 1, s)
        }
        let groups = members.map { root, idxs -> DuplicateGroup in
            let sorted = idxs.map { entries[$0] }.sorted { ($0.filePath, $0.line) < ($1.filePath, $1.line) }
            return DuplicateGroup(entries: sorted, similarity: minScore[root] ?? 0)
        }
        return groups.sorted {
            ($0.entries[0].filePath, $0.entries[0].line) < ($1.entries[0].filePath, $1.entries[0].line)
        }
    }
}
