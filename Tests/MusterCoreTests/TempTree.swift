import Foundation
@testable import MusterCore

/// 测试用的临时目录树。测试往里写文件；生产代码只读或只写它自己的目录（R10）。
final class TempTree {
    let root: String

    init() throws {
        let base = NSTemporaryDirectory() + "muster-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> String {
        let p = path(relative)
        try FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }
}
