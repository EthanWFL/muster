import AppKit
import Foundation

/// 用 release 上的 DMG 就地换掉当前 app，再重启。
/// 走最小路径：挂载 → ditto 到 app 同目录的临时名 → 换名 → 删旧包；
/// 任何一步失败都把旧包换回原位，app 继续能用。
enum UpdateInstaller {
    enum Failure: LocalizedError {
        case noAppInImage
        case replaceFailed(String)
        case command(String)

        var errorDescription: String? {
            switch self {
            case .noAppInImage: return "The DMG contains no .app"
            case .replaceFailed(let reason): return reason
            case .command(let detail): return detail
            }
        }
    }

    /// 换包要在主线程外跑：挂载和拷贝都是阻塞的。
    static func install(dmgURL: URL, replacing appURL: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MusterUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run(["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-quiet", "-mountpoint", mount.path, dmgURL.path])
        defer { try? run(["/usr/bin/hdiutil", "detach", "-quiet", mount.path]) }

        guard let mountedApp = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw Failure.noAppInImage
        }

        // 新包先落到 app 同目录，跨卷换名才安全；名字带前缀，Finder 里不容易被误认。
        let parent = appURL.deletingLastPathComponent()
        let incoming = parent.appendingPathComponent(".Muster-\(UUID().uuidString).new")
        let outgoing = parent.appendingPathComponent(".Muster-\(UUID().uuidString).old")
        try? fm.removeItem(at: incoming)
        try run(["/usr/bin/ditto", mountedApp.path, incoming.path])
        try run(["/usr/bin/codesign", "--verify", "--strict", incoming.path])

        do {
            try fm.moveItem(at: appURL, to: outgoing)
            do {
                try fm.moveItem(at: incoming, to: appURL)
            } catch {
                try? fm.moveItem(at: outgoing, to: appURL)
                throw Failure.replaceFailed(error.localizedDescription)
            }
        } catch let failure as Failure {
            try? fm.removeItem(at: incoming)
            throw failure
        } catch {
            try? fm.removeItem(at: incoming)
            throw Failure.replaceFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: outgoing)
    }

    /// 延迟 1 秒再 `open -n`，让当前进程先退出，否则只是激活旧实例。
    static func relaunch(_ appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open -n \"$1\"", "sh", appURL.path]
        try? process.run()
    }

    private static func run(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure.command("\(URL(fileURLWithPath: args[0]).lastPathComponent) failed: \(text)")
        }
    }
}
