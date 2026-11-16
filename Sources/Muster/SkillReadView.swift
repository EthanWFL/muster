import SwiftUI

/// Local, text-only Markdown preview: no HTML execution or remote image loading.
struct SkillReadView: View {
    let text: String
    let markdown: Bool
    var stripMetadata = false

    struct Block: Equatable {
        enum Kind: Equatable { case paragraph, heading(Int), code }
        let kind: Kind
        let text: String
    }

    static func blocks(_ text: String, stripMetadata: Bool = false) -> [Block] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if stripMetadata, lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            lines = Array(lines.dropFirst(end + 1))
        }
        var result: [Block] = []
        var buffer: [String] = []
        var fence: String?
        func flush(_ kind: Block.Kind) {
            if !buffer.isEmpty { result.append(Block(kind: kind, text: buffer.joined(separator: "\n"))); buffer = [] }
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if trimmed.hasPrefix(marker), trimmed.dropFirst(marker.count).allSatisfy({ $0 == marker.first! }) {
                    flush(.code); fence = nil
                } else { buffer.append(line) }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(.paragraph)
                fence = String(trimmed.prefix(while: { $0 == trimmed.first }))
            } else if trimmed.isEmpty {
                flush(.paragraph)
            } else {
                let depth = line.prefix(while: { $0 == "#" }).count
                if (1...6).contains(depth), line.dropFirst(depth).hasPrefix(" ") {
                    flush(.paragraph)
                    result.append(Block(kind: .heading(depth), text: String(line.dropFirst(depth + 1))))
                } else { buffer.append(line) }
            }
        }
        flush(fence == nil ? .paragraph : .code)
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            if markdown {
                ForEach(Array(Self.blocks(text, stripMetadata: stripMetadata).enumerated()), id: \.offset) { _, block in
                    switch block.kind {
                    case .heading(let depth):
                        Text(inline(block.text)).font(.system(size: depth == 1 ? 21 : (depth == 2 ? 17 : 14), weight: .semibold))
                            .padding(.top, T.s2)
                    case .code:
                        ScrollView(.horizontal) {
                            Text(block.text).font(T.mono).padding(T.s3).frame(maxWidth: .infinity, alignment: .leading)
                        }.background(RoundedRectangle(cornerRadius: T.r).fill(T.card2))
                    case .paragraph:
                        Text(inline(block.text)).font(T.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(text).font(T.mono).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(T.s3).background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
