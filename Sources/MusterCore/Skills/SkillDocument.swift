import Foundation
import CryptoKit
import Yams

public struct SkillDocument: Sendable {
    public let name: String
    public let summary: String
    public let license: String?
    public let warning: String?

    public init(_ text: String) throws {
        guard text.utf8.count <= 1_048_576 else { throw SkillError.tooLarge }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---"), end < 500 else { throw SkillError.invalidDocument }
        let header = lines[1..<end].joined(separator: "\n")
        guard header.utf8.count <= 65_536 else { throw SkillError.tooLarge }
        // Metadata is small and shallow. Bound recursive YAML structures before parsing them.
        guard header.filter({ "[]{}*&".contains($0) }).count <= 128,
              lines[1..<end].allSatisfy({ $0.prefix(while: { $0 == " " || $0 == "\t" }).count <= 64 })
        else { throw SkillError.invalidDocument }
        // Read the mapping's scalar values without constructing arbitrary YAML objects.
        guard let mapping = try? Yams.compose(yaml: header)?.mapping,
              let name = mapping["name"]?.string,
              let description = mapping["description"]?.string,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              description.count <= 1024 else { throw SkillError.invalidDocument }
        let keys = mapping.keys.compactMap(\.string)
        guard keys.count == mapping.count, Set(keys).count == keys.count else { throw SkillError.invalidDocument }
        try Self.validateName(name)
        self.name = name
        summary = description.trimmingCharacters(in: .whitespacesAndNewlines)
        license = mapping["license"]?.string
        warning = name != name.lowercased() || name.contains("_") || name.hasPrefix("-") || name.hasSuffix("-") || name.contains("--")
            ? "This name is not portable to every Agent. Lowercase letters, numbers and single hyphens are recommended." : nil
    }

    public static func validateName(_ name: String) throws {
        guard (1...64).contains(name.count), name != ".", name != "..",
              name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
        else { throw SkillError.unsafeName }
    }

    public static func template(name: String, description: String) throws -> String {
        try validateName(name)
        let quoted = String(data: try JSONEncoder().encode(description), encoding: .utf8)!
        let text = "---\nname: \(name)\ndescription: \(quoted)\n---\n\n# \(name)\n\n"
        _ = try SkillDocument(text)
        return text
    }
}

/// Bounded, no-follow file traversal shared by imports, fingerprints and copies.
enum SkillFiles {
    struct File {
        let path: String
        let data: Data
        let executable: Bool
    }
    static func read(_ directory: URL) throws -> [File] {
        let fm = FileManager.default
        let root = directory.standardizedFileURL
        guard try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else { throw SkillError.unsafeTree }
        var files: [File] = [], total = 0, visited = 0
        func walk(_ dir: URL, _ prefix: String, _ depth: Int, descriptor: Int32) throws {
            guard depth <= 20 else { throw SkillError.tooLarge }
            for url in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                let name = url.lastPathComponent
                if name == ".git" || name == ".DS_Store" { continue }
                visited += 1
                guard visited <= 2_000 else { throw SkillError.tooLarge }
                let attrs = try fm.attributesOfItem(atPath: url.path)
                let type = attrs[.type] as? FileAttributeType
                let relative = prefix + name
                if type == .typeDirectory {
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard child >= 0 else { throw SkillError.unsafeTree }
                    defer { close(child) }
                    try walk(url, relative + "/", depth + 1, descriptor: child)
                }
                else if type == .typeRegular {
                    let size = (attrs[.size] as? NSNumber)?.intValue ?? Int.max
                    guard size <= 32 * 1024 * 1024 - total else { throw SkillError.tooLarge }
                    let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    guard fd >= 0 else { throw SkillError.unsafeTree }
                    var info = stat()
                    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(fd); throw SkillError.unsafeTree }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    var data = Data()
                    while let chunk = try handle.read(upToCount: min(1_048_576, 32 * 1024 * 1024 - total - data.count + 1)), !chunk.isEmpty {
                        data.append(chunk)
                        guard data.count + total <= 32 * 1024 * 1024 else { throw SkillError.tooLarge }
                    }
                    try handle.close()
                    total += data.count
                    guard total <= 32 * 1024 * 1024 else { throw SkillError.tooLarge }
                    files.append(File(path: relative, data: data, executable: info.st_mode & 0o111 != 0))
                } else { throw SkillError.unsafeTree }
            }
        }
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SkillError.unsafeTree }
        defer { close(descriptor) }
        try walk(root, "", 0, descriptor: descriptor)
        return files
    }

    static func hash(_ files: [File]) -> String {
        var hash = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data("\(file.path.utf8.count):\(file.path):\(file.executable):\(file.data.count):".utf8))
            hash.update(data: file.data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func write(_ files: [File], to root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for file in files {
            let url = root.appendingPathComponent(file.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: url.path, contents: file.data, attributes: [.posixPermissions: file.executable ? 0o700 : 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    static func fingerprint(_ url: URL) throws -> String {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return "missing"
        }
        if info.st_mode & S_IFMT == S_IFLNK { return "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path)) }
        if info.st_mode & S_IFMT == S_IFDIR { return "tree:" + hash(try read(url)) }
        return "other"
    }

    static func document(_ files: [File]) throws -> (String, SkillDocument) {
        guard let data = files.first(where: { $0.path == "SKILL.md" })?.data,
              let text = String(data: data, encoding: .utf8) else { throw SkillError.invalidDocument }
        return (text, try SkillDocument(text))
    }
}

public enum SkillScanner {
    public static func candidates(at directory: URL, source: SkillSource? = nil) throws -> [SkillCandidate] {
        let fm = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        var result: [SkillCandidate] = [], count = 0
        func walk(_ dir: URL, _ depth: Int) throws {
            try Task.checkCancellation()
            count += 1
            guard count <= 3_000, depth <= 10 else { throw SkillError.scanLimit }
            if fm.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) {
                var origin = source ?? SkillSource(kind: .local, location: dir.path)
                if origin.kind == .git {
                    let relative = String(dir.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    origin.subdirectory = [origin.subdirectory, relative].filter { !$0.isEmpty }.joined(separator: "/")
                }
                do {
                    let files = try SkillFiles.read(dir)
                    let (_, document) = try SkillFiles.document(files)
                    result.append(SkillCandidate(directory: dir, name: document.name, summary: document.summary, license: document.license,
                        warning: document.warning, digest: SkillFiles.hash(files), files: files.map(\.path), source: origin))
                } catch is CancellationError { throw CancellationError() }
                  catch {
                    result.append(SkillCandidate(directory: dir, name: dir.lastPathComponent, summary: "", license: nil,
                        warning: error.localizedDescription, digest: "", files: [], source: origin))
                }
                return
            }
            for url in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                guard ![".git", "node_modules", ".build", ".venv"].contains(url.lastPathComponent) else { continue }
                if try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory { try walk(url, depth + 1) }
            }
        }
        try walk(root, 0)
        return result
    }
}
