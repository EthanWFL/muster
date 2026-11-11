import Foundation

/// Finds rules that disagree about a whitelisted topic (see `ContradictionTopic.defaults`).
///
/// Only an option mentioned together with a directive cue counts ("use pnpm", "never npm", "禁止使用 npm").
/// A bare mention such as `npm run build` has no stance and is ignored. When an entry mentions several
/// options of one topic and at least one has no stance ("pnpm or npm"), the entry is skipped for that
/// topic: it is ambiguous, and a missed contradiction is cheaper than a false one.
public struct ContradictionDetector: Sendable {
    public var topics: [ContradictionTopic]
    public var cues: DirectiveCues
    /// When false (default) two entries only conflict if they live in different repos.
    public var includeSameRepo: Bool
    /// How many characters before a mention are searched for a cue.
    public var beforeWindow: Int
    /// How many characters after a mention are searched for a cue.
    public var afterWindow: Int

    public init(
        topics: [ContradictionTopic] = ContradictionTopic.defaults,
        cues: DirectiveCues = .default,
        includeSameRepo: Bool = false,
        beforeWindow: Int = 32,
        afterWindow: Int = 16
    ) {
        self.topics = topics
        self.cues = cues
        self.includeSameRepo = includeSameRepo
        self.beforeWindow = beforeWindow
        self.afterWindow = afterWindow
    }

    private static let separators: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "\n", "(", ")",
        "\u{FF0C}", "\u{3002}", "\u{FF1B}", "\u{FF1A}", "\u{FF01}", "\u{FF1F}", "\u{3001}", "\u{FF08}", "\u{FF09}",
    ]

    struct OptionStance {
        var topic: Int
        var option: String
        var stance: DirectiveStance
    }

    // MARK: Public

    public func findContradictions(in entries: [RuleEntry]) -> [Contradiction] {
        var table = [[String: [DirectiveStance: [RuleEntry]]]](repeating: [:], count: topics.count)
        for entry in entries {
            for s in stances(of: entry) {
                table[s.topic][s.option, default: [:]][s.stance, default: []].append(entry)
            }
        }

        var result: [Contradiction] = []
        for (ti, topic) in topics.enumerated() {
            let byOption = table[ti]
            let names = topic.options.map(\.name).filter { byOption[$0] != nil }

            for name in names {
                guard let reqs = byOption[name]?[.require], let forbs = byOption[name]?[.forbid] else { continue }
                let r = reqs.filter { a in forbs.contains { differs(a, $0) } }
                let f = forbs.filter { b in reqs.contains { differs($0, b) } }
                guard !r.isEmpty, !f.isEmpty else { continue }
                let positions = [
                    ContradictionPosition(option: name, stance: .require, entries: Self.sorted(r)),
                    ContradictionPosition(option: name, stance: .forbid, entries: Self.sorted(f)),
                ]
                result.append(Contradiction(
                    topicID: topic.id, topicTitle: topic.title, kind: .requireVersusForbid, positions: positions,
                    summary: "\(name) is required at \(positions[0].entries[0].location) but forbidden at \(positions[1].entries[0].location)"))
            }

            for i in names.indices {
                for j in names.indices where j > i {
                    guard let a = byOption[names[i]]?[.require], let b = byOption[names[j]]?[.require] else { continue }
                    let ra = a.filter { x in b.contains { differs(x, $0) } }
                    let rb = b.filter { y in a.contains { differs($0, y) } }
                    guard !ra.isEmpty, !rb.isEmpty else { continue }
                    let positions = [
                        ContradictionPosition(option: names[i], stance: .require, entries: Self.sorted(ra)),
                        ContradictionPosition(option: names[j], stance: .require, entries: Self.sorted(rb)),
                    ]
                    result.append(Contradiction(
                        topicID: topic.id, topicTitle: topic.title, kind: .conflictingChoice, positions: positions,
                        summary: "\(names[i]) is required at \(positions[0].entries[0].location) but \(names[j]) is required at \(positions[1].entries[0].location)"))
                }
            }
        }
        return result
    }

    // MARK: Stance extraction

    func stances(of entry: RuleEntry) -> [OptionStance] {
        let hay = Array(entry.text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"))
        var out: [OptionStance] = []

        for (ti, topic) in topics.enumerated() {
            let mentions = Self.mentions(of: topic, in: hay)
            guard !mentions.isEmpty else { continue }

            var perOption: [String: Set<DirectiveStance>] = [:]
            var order: [String] = []
            for (k, m) in mentions.enumerated() {
                if perOption[m.option] == nil { perOption[m.option] = []; order.append(m.option) }
                let prevEnd = k > 0 ? mentions[k - 1].end : 0
                let nextStart = k + 1 < mentions.count ? mentions[k + 1].start : hay.count
                if let s = stance(in: hay, mention: m, prevEnd: prevEnd, nextStart: nextStart) {
                    perOption[m.option]?.insert(s)
                }
            }
            // Ambiguous within the entry: several options and one has no stance, or both stances on one option.
            let neutral = order.contains { perOption[$0]?.isEmpty ?? true }
            if order.count >= 2 && neutral { continue }
            for option in order {
                guard let set = perOption[option], set.count == 1, let s = set.first else { continue }
                out.append(OptionStance(topic: ti, option: option, stance: s))
            }
        }
        return out
    }

    private struct Mention {
        var option: String
        var start: Int
        var end: Int
    }

    private static func mentions(of topic: ContradictionTopic, in hay: [Character]) -> [Mention] {
        var found: [Mention] = []
        for option in topic.options {
            for alias in option.aliases {
                let a = Array(alias.lowercased())
                for i in matches(a, in: hay, range: 0..<hay.count) {
                    found.append(Mention(option: option.name, start: i, end: i + a.count))
                }
            }
        }
        found.sort { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
        var kept: [Mention] = []
        for m in found where m.start >= (kept.last?.end ?? 0) { kept.append(m) }
        return kept
    }

    private func stance(in hay: [Character], mention m: Mention, prevEnd: Int, nextStart: Int) -> DirectiveStance? {
        // Cue before the mention: the closest one wins.
        var lo = max(prevEnd, m.start - beforeWindow, 0)
        var j = m.start - 1
        while j >= lo {
            if Self.separators.contains(hay[j]) { lo = j + 1; break }
            j -= 1
        }
        if lo < m.start, let cue = closestCueBefore(hay, lo..<m.start) {
            if cue.stance == .require && negated(hay, cueStart: cue.start, lowerBound: lo) { return .forbid }
            return cue.stance
        }

        // Otherwise a cue right behind it ("pnpm is required").
        var hi = min(nextStart, m.end + afterWindow, hay.count)
        var k = m.end
        while k < hi {
            if Self.separators.contains(hay[k]) { hi = k; break }
            k += 1
        }
        if m.end < hi, let cue = firstCueAfter(hay, m.end..<hi) { return cue.stance }
        return nil
    }

    private struct Cue {
        var start: Int
        var end: Int
        var stance: DirectiveStance
    }

    private func closestCueBefore(_ hay: [Character], _ range: Range<Int>) -> Cue? {
        var best: Cue?
        func consider(_ list: [String], _ stance: DirectiveStance) {
            for cue in list {
                let c = Array(cue)
                for i in Self.matches(c, in: hay, range: range) {
                    let cand = Cue(start: i, end: i + c.count, stance: stance)
                    if let b = best {
                        let longer = (cand.end - cand.start) > (b.end - b.start)
                        if cand.end > b.end || (cand.end == b.end && longer) { best = cand }
                    } else {
                        best = cand
                    }
                }
            }
        }
        consider(cues.requireBefore, .require)
        consider(cues.forbidBefore, .forbid)
        return best
    }

    private func firstCueAfter(_ hay: [Character], _ range: Range<Int>) -> Cue? {
        var best: Cue?
        func consider(_ list: [String], _ stance: DirectiveStance) {
            for cue in list {
                let c = Array(cue)
                for i in Self.matches(c, in: hay, range: range) {
                    let cand = Cue(start: i, end: i + c.count, stance: stance)
                    if let b = best {
                        let longer = (cand.end - cand.start) > (b.end - b.start)
                        if cand.start < b.start || (cand.start == b.start && longer) { best = cand }
                    } else {
                        best = cand
                    }
                }
            }
        }
        consider(cues.requireAfter, .require)
        consider(cues.forbidAfter, .forbid)
        return best
    }

    /// True when a negator ends right before `cueStart` (whitespace allowed in between).
    private func negated(_ hay: [Character], cueStart: Int, lowerBound: Int) -> Bool {
        var end = cueStart
        while end > lowerBound, hay[end - 1].isWhitespace { end -= 1 }
        guard end > lowerBound else { return false }
        for neg in cues.negators {
            let n = Array(neg)
            let s = end - n.count
            guard s >= lowerBound, Array(hay[s..<end]) == n else { continue }
            if let f = n.first, Self.isASCIIAlnum(f), s > 0, Self.isASCIIAlnum(hay[s - 1]) { continue }
            return true
        }
        return false
    }

    // MARK: Helpers

    private func differs(_ a: RuleEntry, _ b: RuleEntry) -> Bool {
        guard a.filePath != b.filePath else { return false }
        return includeSameRepo || a.repoRoot != b.repoRoot
    }

    private static func sorted(_ entries: [RuleEntry]) -> [RuleEntry] {
        Array(Set(entries)).sorted { ($0.filePath, $0.line) < ($1.filePath, $1.line) }
    }

    private static func isASCIIAlnum(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    /// Start indices of `needle` inside `range`. ASCII words must sit on a word boundary
    /// ("npm" does not match inside "pnpm", "use" not inside "because"). CJK needles match anywhere.
    private static func matches(_ needle: [Character], in hay: [Character], range: Range<Int>) -> [Int] {
        guard let first = needle.first, let last = needle.last, range.count >= needle.count else { return [] }
        var out: [Int] = []
        var i = range.lowerBound
        let stop = range.upperBound - needle.count
        while i <= stop {
            if hay[i] == first, hay[i..<(i + needle.count)].elementsEqual(needle) {
                let leftOK = !isASCIIAlnum(first) || i == 0 || !isASCIIAlnum(hay[i - 1])
                let right = i + needle.count
                let rightOK = !isASCIIAlnum(last) || right >= hay.count || !isASCIIAlnum(hay[right])
                if leftOK && rightOK { out.append(i) }
            }
            i += 1
        }
        return out
    }
}
