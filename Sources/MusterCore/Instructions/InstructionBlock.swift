import CryptoKit
import Foundation

/// 写进 agent 指令文件的那一段，由两行标记框住。
///
/// 文件里除了这两行标记之间的内容，其余全部是用户自己的，Muster 永不改动。
/// 这样一份共享指令可以同时喂给多个 agent，撤掉时也只撤自己写的那段。
public enum InstructionBlock {
    public static let begin = "<!-- muster:begin · written by Muster from its shared instructions -->"
    public static let end = "<!-- muster:end -->"

    /// 切成「用户前半段 / Muster 那段 / 用户后半段」。文件里没有 Muster 的段时返回 nil。
    public static func split(_ file: String) -> (before: String, block: String, after: String)? {
        let text = normalized(file)
        guard let start = text.range(of: begin) else { return nil }
        let rest = text[start.upperBound...]
        guard let stop = rest.range(of: end) else { return nil }
        return (
            String(text[..<start.lowerBound]),
            rest[..<stop.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines),
            String(rest[stop.upperBound...])
        )
    }

    /// 文件里属于用户自己的内容：去掉 Muster 的段（连同一根残留的结束标记）。
    public static func own(_ file: String) -> String {
        var text = normalized(file)
        while let parts = split(text) {
            text = parts.before.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n"
                + parts.after.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 段被写进段里（`withBlock` 的旧 bug）会留下多余的结束标记，按行清掉。
        if text.contains(end) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.trimmingCharacters(in: .whitespaces) != end }
            text = lines.joined(separator: "\n")
            while text.contains("\n\n\n") {
                text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把文件里的 Muster 段换成 `text`；`text` 为空表示撤掉这段。
    /// 新段追加在用户已有内容之后。
    public static func withBlock(_ file: String, _ text: String) -> String {
        var before: String
        var after: String
        if let parts = split(file) {
            before = parts.before
            after = parts.after
        } else {
            before = normalized(file)
            after = ""
        }
        while before.hasSuffix("\n") { before.removeLast() }
        while after.hasPrefix("\n") { after.removeFirst() }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = trimmed.isEmpty ? "" : begin + "\n" + trimmed + "\n" + end
        var pieces: [String] = []
        for piece in [before, block, after] where !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pieces.append(piece.hasSuffix("\n") ? String(piece.dropLast()) : piece)
        }
        return pieces.isEmpty ? "" : pieces.joined(separator: "\n\n") + "\n"
    }

    /// 用户自有内容的行数，界面上的「自有 N 行」。
    public static func ownLineCount(_ file: String) -> Int {
        own(file).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    /// 用来判断「文件里的段有没有被人手改过」的短指纹。
    public static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(normalized(text).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }
}
