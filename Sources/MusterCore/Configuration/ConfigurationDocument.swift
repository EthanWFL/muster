import Foundation

/// Byte ranges keep unrelated JSON values, ordering, whitespace and TOML comments intact.
struct ConfigurationDocument {
    let data: Data
    let json: Bool
    private(set) var values: [String: String] = [:]
    private var ranges: [String: Range<Int>] = [:]
    private var insertion = 0
    private var hasJSONMembers = false

    init(data: Data, json: Bool, keys: [String]) throws {
        self.data = data
        self.json = json
        guard String(data: data, encoding: .utf8) != nil else { throw ConfigurationError.invalid }
        if json { try scanJSON(keys: keys) } else { try scanTOML(keys: keys) }
    }

    func replacing(_ changes: [String: String]) throws -> Data {
        var bytes = Array(data)
        var edits: [(Range<Int>, [UInt8])] = []
        var additions: [String] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for key in changes.keys.sorted() {
            let encoded = String(decoding: try encoder.encode(changes[key]!), as: UTF8.self)
            if let range = ranges[key] { edits.append((range, Array(encoded.utf8))) }
            else { additions.append(json ? "  \"\(key)\": \(encoded)" : "\(key) = \(encoded)") }
        }
        if !additions.isEmpty {
            let newline = String(decoding: data, as: UTF8.self).contains("\r\n") ? "\r\n" : "\n"
            let text = json
                ? (hasJSONMembers ? "," : "") + newline + additions.joined(separator: "," + newline) + newline
                : additions.joined(separator: newline) + newline
            edits.append((insertion..<insertion, Array(text.utf8)))
        }
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            bytes.replaceSubrange(range, with: replacement)
        }
        let output = Data(bytes)
        _ = try ConfigurationDocument(data: output, json: json, keys: Array(changes.keys))
        return output
    }

    private mutating func record(_ key: String, range: Range<Int>, value: String) throws {
        guard ranges[key] == nil else { throw ConfigurationError.invalid }
        ranges[key] = range
        values[key] = value
    }

    private mutating func scanJSON(keys: [String]) throws {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw ConfigurationError.invalid }
        let bytes = Array(data)
        var i = 0
        func skipSpace() { while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
        func stringEnd(_ start: Int) -> Int {
            var end = start + 1
            while end < bytes.count {
                if bytes[end] == 92 { end += 2; continue }
                if bytes[end] == 34 { return end + 1 }
                end += 1
            }
            return bytes.count
        }
        skipSpace()
        i += 1 // root object, already validated by Foundation
        while i < bytes.count {
            skipSpace()
            if bytes[i] == 125 { insertion = i; break }
            let keyEnd = stringEnd(i)
            let key = try JSONDecoder().decode(String.self, from: Data(bytes[i..<keyEnd]))
            i = keyEnd
            skipSpace()
            i += 1 // colon
            skipSpace()
            let start = i
            var depth = 0
            while i < bytes.count {
                let byte = bytes[i]
                if byte == 34 { i = stringEnd(i); continue }
                if depth == 0 && (byte == 44 || byte == 125) { break }
                if byte == 91 || byte == 123 { depth += 1 }
                if byte == 93 || byte == 125 { depth -= 1 }
                i += 1
            }
            var end = i
            while end > start && [9, 10, 13, 32].contains(bytes[end - 1]) { end -= 1 }
            if keys.contains(key) {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<end])) else {
                    throw ConfigurationError.invalid
                }
                try record(key, range: start..<end, value: value)
            }
            hasJSONMembers = true
            if bytes[i] == 44 { i += 1 }
        }
    }

    private mutating func scanTOML(keys: [String]) throws {
        let bytes = Array(data)
        var start = 0
        insertion = 0 // Missing root fields must precede all tables.
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.count
            let line = String(decoding: bytes[start..<end], as: UTF8.self)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") { break }
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                // shortcut: multiline root values are read-only until a full TOML parser is needed.
                // Reject them rather than confusing embedded strings with actual root settings.
                let contentEnd = try Self.singleLineEnd(Array(line.utf8))
                let content = Array(line.utf8)[..<contentEnd]
                guard let equal = content.firstIndex(of: 61) else { throw ConfigurationError.unsupported }
                let rawKey = String(decoding: content[..<equal], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                let key: String
                if rawKey.hasPrefix("\"") {
                    guard let decoded = try? JSONDecoder().decode(String.self, from: Data(rawKey.utf8)) else {
                        throw ConfigurationError.unsupported
                    }
                    key = decoded
                } else if rawKey.hasPrefix("'"), rawKey.hasSuffix("'") {
                    key = String(rawKey.dropFirst().dropLast())
                } else { key = rawKey }
                if keys.contains(key) {
                    var lower = equal + 1
                    var upper = contentEnd
                    while lower < upper && [9, 13, 32].contains(content[lower]) { lower += 1 }
                    while upper > lower && [9, 13, 32].contains(content[upper - 1]) { upper -= 1 }
                    let rawValue = String(decoding: content[lower..<upper], as: UTF8.self)
                    let value: String
                    if rawValue.hasPrefix("'"), rawValue.hasSuffix("'"), rawValue.count >= 2 {
                        value = String(rawValue.dropFirst().dropLast())
                        guard !value.contains("'") else { throw ConfigurationError.unsupported }
                    } else if let decoded = try? JSONDecoder().decode(String.self, from: Data(rawValue.utf8)) {
                        value = decoded
                    } else { throw ConfigurationError.unsupported }
                    try record(key, range: (start + lower)..<(start + upper), value: value)
                }
            }
            start = end + 1
        }
    }

    /// Find a comment outside strings and reject incomplete/multiline root statements.
    private static func singleLineEnd(_ bytes: [UInt8]) throws -> Int {
        var quote: UInt8?
        var brackets: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if let q = quote {
                if b == 92 && q == 34 { i += 2; continue }
                if b == q { quote = nil }
            } else {
                if b == 35 { break }
                if b == 34 || b == 39 {
                    if i + 2 < bytes.count && bytes[i + 1] == b && bytes[i + 2] == b {
                        throw ConfigurationError.unsupported
                    }
                    quote = b
                }
                if b == 91 || b == 123 { brackets.append(b) }
                if b == 93 || b == 125 {
                    guard brackets.popLast() == (b == 93 ? 91 : 123) else { throw ConfigurationError.unsupported }
                }
            }
            i += 1
        }
        guard quote == nil, brackets.isEmpty else { throw ConfigurationError.unsupported }
        return i
    }
}
