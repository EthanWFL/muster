import AppKit
import Foundation
import MusterCore

/// 用 release 上的 DMG 就地换掉当前 app，再重启。
/// 校验发布签名后挂载，检查候选 app，再换名替换；失败时尝试恢复旧包。
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
    static func install(dmgURL: URL, signature: Data, publicKey: String?, version: String,
                        currentVersion: String, replacing appURL: URL) throws {
        // Verify the publisher before asking the OS to mount any downloaded image.
        try UpdateTrust.verify(image: dmgURL, signature: signature, publicKey: publicKey)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MusterUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }

        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run(["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-quiet", "-mountpoint", mount.path, dmgURL.path])
        defer { try? run(["/usr/bin/hdiutil", "detach", "-quiet", mount.path]) }

        let mountedApp = mount.appendingPathComponent("Muster.app")
        guard fm.fileExists(atPath: mountedApp.path),
              (try mountedApp.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw Failure.noAppInImage
        }

        // 新包先落到 app 同目录，跨卷换名才安全；名字带前缀，Finder 里不容易被误认。
        let parent = appURL.deletingLastPathComponent()
        let incoming = parent.appendingPathComponent(".Muster-\(UUID().uuidString).new")
        let outgoing = parent.appendingPathComponent(".Muster-\(UUID().uuidString).old")
        defer { try? fm.removeItem(at: incoming) }
        try run(["/usr/bin/ditto", mountedApp.path, incoming.path])
        try run(["/usr/bin/codesign", "--verify", "--deep", "--strict", incoming.path])
        let infoData = try Data(contentsOf: incoming.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
            throw UpdateTrustError.wrongApplication
        }
        try UpdateTrust.validateBundle(info: info, expectedVersion: version, currentVersion: currentVersion)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        try run(["/usr/bin/lipo", incoming.appendingPathComponent("Contents/MacOS/Muster").path, "-verify_arch", architecture])

        do {
            try fm.moveItem(at: appURL, to: outgoing)
            do {
                try fm.moveItem(at: incoming, to: appURL)
            } catch {
                let replacementError = error
                do { try fm.moveItem(at: outgoing, to: appURL) }
                catch {
                    throw Failure.replaceFailed("\(replacementError.localizedDescription)\nRestore failed; the previous app is at \(outgoing.path)")
                }
                throw Failure.replaceFailed(replacementError.localizedDescription)
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
        let result = try CleanupCommandRunner().run(args, cwd: nil)
        guard result.status == 0 else {
            throw Failure.command("\(URL(fileURLWithPath: args[0]).lastPathComponent) failed: \(result.stderr)")
        }
    }
}
