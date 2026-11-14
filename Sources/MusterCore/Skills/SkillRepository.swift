import Foundation

public struct SkillCheckout: Sendable {
    public let temporaryDirectory: URL
    public let candidates: [SkillCandidate]
    public func cleanup() { try? FileManager.default.removeItem(at: temporaryDirectory) }
}

public enum SkillRepository {
    public static func normalizedURL(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortParts = value.split(separator: "/", omittingEmptySubsequences: false)
        let address = !value.contains(":") && shortParts.count == 2 ? "https://github.com/" + value : value
        guard let url = URLComponents(string: address), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !url.path.isEmpty, !address.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw SkillError.invalidRepository }
        if host.lowercased() == "github.com" {
            let parts = url.path.split(separator: "/")
            guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } })
            else { throw SkillError.invalidRepository }
        }
        return address
    }

    public static func fetch(_ source: SkillSource) async throws -> SkillCheckout {
        let address = try normalizedURL(source.location)
        guard !source.ref.hasPrefix("-"), !source.ref.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !source.subdirectory.hasPrefix("/"), !source.subdirectory.split(separator: "/").contains("..") else { throw SkillError.invalidRepository }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("muster-skills-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let repo = temporary.appendingPathComponent("repository")
            var args = ["clone", "--depth", "1", "--single-branch", "--no-checkout", "--no-recurse-submodules", "--template="]
            if !source.ref.isEmpty { args += ["--branch", source.ref] }
            args += ["--", address, repo.path]
            _ = try await run(args, temporary: temporary)
            _ = try await run(["-C", repo.path, "-c", "core.symlinks=true", "checkout", "--force", "HEAD"], temporary: temporary)
            let commit = try await run(["-C", repo.path, "rev-parse", "HEAD"], temporary: temporary).trimmingCharacters(in: .whitespacesAndNewlines)
            guard commit.count == 40 || commit.count == 64, commit.allSatisfy(\.isHexDigit) else { throw SkillError.gitFailed }
            let selected = repo.appendingPathComponent(source.subdirectory).standardizedFileURL
            let resolved = selected.resolvingSymlinksInPath().path
            guard (selected.path == repo.path || selected.path.hasPrefix(repo.path + "/")),
                  (resolved == repo.resolvingSymlinksInPath().path || resolved.hasPrefix(repo.resolvingSymlinksInPath().path + "/"))
            else { throw SkillError.invalidPath }
            let origin = SkillSource(kind: .git, location: address, ref: source.ref, subdirectory: source.subdirectory, commit: commit)
            let candidates = try SkillScanner.candidates(at: selected, source: origin)
            return SkillCheckout(temporaryDirectory: temporary, candidates: candidates)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func run(_ arguments: [String], temporary: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "protocol.allow=never",
            "-c", "protocol.https.allow=always", "-c", "filter.lfs.required=false", "-c", "filter.lfs.smudge=", "-c", "filter.lfs.process="] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0", "GIT_LFS_SKIP_SMUDGE": "1", "LC_ALL": "C"]
        let output = temporary.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(90)
        do {
            var poll = 0
            while process.isRunning {
                try Task.checkCancellation()
                if Date() > deadline { throw SkillError.gitTimedOut }
                if poll % 10 == 0 {
                    let urls = FileManager.default.enumerator(at: temporary, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
                    var bytes = 0
                    while let url = urls?.nextObject() as? URL {
                        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
                        if bytes > 128 * 1024 * 1024 { throw SkillError.gitTimedOut }
                    }
                }
                poll += 1
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            if process.isRunning { process.terminate() }
            // Reap before removing the private staging directory.
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else { throw SkillError.gitFailed }
        try handle.synchronize()
        let data = try Data(contentsOf: output)
        return String(decoding: data.suffix(4096), as: UTF8.self)
    }
}
