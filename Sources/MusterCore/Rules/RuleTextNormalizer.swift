import Foundation

/// Turns rule text into a token set for Jaccard comparison.
///
/// Lowercases, strips punctuation, drops stopwords. Space-delimited text yields word tokens.
/// CJK runs (no spaces between words) yield character bigrams, or a single character for a run of one.
public enum RuleTextNormalizer {
    public static let englishStopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are", "be", "been",
        "this", "that", "these", "those", "it", "its", "as", "at", "by", "from", "you", "we", "your", "our",
        "should", "shall", "will", "can", "may", "please", "always", "also", "then", "so", "any", "all",
        "when", "if", "which", "there", "their", "them", "have", "has", "do", "does", "make", "sure",
    ]

    /// Single CJK characters that carry no meaning on their own. A stop character also ends a run,
    /// so no bigram spans it.
    public static let cjkStopCharacters: Set<Character> = [
        "的", "了", "是", "在", "和", "与", "及", "请", "把", "将", "并", "也", "都", "就", "地", "得", "着",
    ]

    public static func tokens(_ text: String) -> Set<String> {
        var result = Set<String>()
        var word = String.UnicodeScalarView()
        var run: [Character] = []

        func flushWord() {
            defer { word.removeAll() }
            guard !word.isEmpty else { return }
            let w = String(word)
            if englishStopwords.contains(w) { return }
            if w.unicodeScalars.count == 1, let s = w.unicodeScalars.first, s.isASCII, !(48...57).contains(s.value) {
                return
            }
            result.insert(w)
        }
        func flushRun() {
            defer { run.removeAll() }
            if run.count == 1 {
                result.insert(String(run[0]))
            } else if run.count >= 2 {
                for i in 0..<(run.count - 1) { result.insert(String([run[i], run[i + 1]])) }
            }
        }

        for scalar in text.lowercased().unicodeScalars {
            if isCJK(scalar) {
                flushWord()
                let ch = Character(scalar)
                if cjkStopCharacters.contains(ch) { flushRun() } else { run.append(ch) }
            } else if CharacterSet.alphanumerics.contains(scalar) {
                flushRun()
                word.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue  // don't -> dont
            } else {
                flushWord()
                flushRun()
            }
        }
        flushWord()
        flushRun()
        return result
    }

    public static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF,
             0x3040...0x309F, 0x30A0...0x30FF:
            return true
        default:
            return false
        }
    }

    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let inter = a.count < b.count ? a.intersection(b).count : b.intersection(a).count
        let union = a.count + b.count - inter
        return union == 0 ? 0 : Double(inter) / Double(union)
    }
}
