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
        let installed = try validateDestination(appURL, version: currentVersion, publicKey: publicKey)
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
        try UpdateTrust.validateBundle(info: info, expectedVersion: version, currentVersion: currentVersion, expectedPublicKey: publicKey)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        try run(["/usr/bin/lipo", incoming.appendingPathComponent("Contents/MacOS/Muster").path, "-verify_arch", architecture])

        guard try validateDestination(appURL, version: currentVersion, publicKey: publicKey) == installed else {
            throw UpdateTrustError.destinationChanged
        }

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

    /// Wait for the old process to exit before launching this exact app path.
    static func relaunch(_ appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "attempt=0; while kill -0 \"$2\" 2>/dev/null; do attempt=$((attempt + 1)); [ \"$attempt\" -lt 300 ] || exit 1; /bin/sleep 0.2; done; exec /usr/bin/open -n \"$1\"", "sh", appURL.path, String(getpid())]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private struct InstalledApp: Equatable {
        let path: String
        let inode: UInt64
        let device: UInt64
        let info: Data
    }

    private static func validateDestination(_ app: URL, version: String, publicKey: String?) throws -> InstalledApp {
        let fm = FileManager.default
        guard app.isFileURL, app.pathExtension == "app", UpdateTrust.hasValidKey(publicKey) else { throw UpdateTrustError.invalidDestination }
        let attributes = try fm.attributesOfItem(atPath: app.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw UpdateTrustError.invalidDestination }
        let infoData = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.muster.app",
              info["CFBundleExecutable"] as? String == "Muster",
              info["CFBundleShortVersionString"] as? String == version,
              info["MusterUpdatePublicKey"] as? String == publicKey,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value else { throw UpdateTrustError.invalidDestination }
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else { throw UpdateTrustError.destinationNotWritable }
        try run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app.path])
        return InstalledApp(path: app.resolvingSymlinksInPath().path, inode: inode, device: device, info: infoData)
    }

    private static func run(_ args: [String]) throws {
        let result = try CleanupCommandRunner().run(args, cwd: nil)
        guard result.status == 0 else {
            throw Failure.command("\(URL(fileURLWithPath: args[0]).lastPathComponent) failed: \(result.stderr)")
        }
    }
}
