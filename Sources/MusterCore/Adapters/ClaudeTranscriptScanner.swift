import Foundation
import os

/// Receives diagnostic messages. Messages must never contain transcript content:
/// only file names and failure reasons.
public typealias DiagnosticSink = @Sendable (String) -> Void

public enum Diagnostics {
    private static let logger = Logger(subsystem: "Muster", category: "sessions")
    public static let `default`: DiagnosticSink = { message in
        logger.info("\(message, privacy: .public)")
    }
}

/// Infers Claude Code sessions from `<projectsRoot>/<encoded-cwd>/<sessionId>.jsonl`.
///
/// Only the head and the tail of each file are read (bounded chunks); a transcript is never
/// loaded whole and no conversation text is kept. Only `sessionId`, `cwd` and `timestamp`
/// are decoded from each line; every other field is ignored.
public struct ClaudeTranscriptScanner: Sendable {
    /// Bytes read from the start and from the end of each file.
    public static let chunkSize = 64 * 1024

    public let projectsRoot: URL
    public let clock: Clock
    public let retention: TimeInterval
    public let log: DiagnosticSink

    public init(
        projectsRoot: URL, clock: Clock = SystemClock(),
        retention: TimeInterval = SessionPolicy.defaultRetention,
        log: @escaping DiagnosticSink = Diagnostics.default
    ) {
        self.projectsRoot = projectsRoot
        self.clock = clock
        self.retention = retention
        self.log = log
    }

    /// The only fields we depend on.
    struct Line: Decodable {
        var sessionId: String?
        var cwd: String?
        var timestamp: String?
    }

    public func scan() throws -> [Session] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsRoot.path) else { return [] }
        let cutoff = clock.now().addingTimeInterval(-retention)
        var result: [Session] = []
        let dirs = try fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, let mtime = values.contentModificationDate,
                      mtime >= cutoff else { continue }
                if let session = inspect(file: file, mtime: mtime) { result.append(session) }
            }
        }
        return result.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func inspect(file: URL, mtime: Date) -> Session? {
        let name = file.lastPathComponent
        let head: [Line], tail: [Line]
        do {
            (head, tail) = try readEnds(of: file)
        } catch {
            log("skip \(name): unreadable (\(error.localizedDescription))")
            return nil
        }
        let all = head + tail
        let stem = file.deletingPathExtension().lastPathComponent
        let id = all.compactMap(\.sessionId).first ?? stem
        guard let cwd = head.compactMap(\.cwd).first ?? tail.compactMap(\.cwd).first else {
            log("skip \(name): no cwd in head or tail")
            return nil
        }
        let parser = TimestampParser()
        let started = head.compactMap { $0.timestamp.flatMap(parser.parse) }.first ?? mtime
        return Session(id: id, agent: .claude, cwd: cwd, startedAt: min(started, mtime),
                       lastActivityAt: mtime, state: .idle)
    }

    /// Reads at most `chunkSize` bytes from each end and decodes the complete lines in them.
    func readEnds(of file: URL) throws -> ([Line], [Line]) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let chunk = UInt64(Self.chunkSize)
        try handle.seek(toOffset: 0)
        let headData = try handle.read(upToCount: Self.chunkSize) ?? Data()
        // A head chunk that stops mid-line must not be parsed as a full line.
        let headTruncated = size > chunk
        var tailData = Data()
        var tailTruncated = false
        if size > chunk {
            try handle.seek(toOffset: size - chunk)
            tailData = try handle.read(upToCount: Self.chunkSize) ?? Data()
            tailTruncated = true
        }
        let name = file.lastPathComponent
        let head = decode(headData, dropFirst: false, dropLast: headTruncated, name: name)
        let tail = size > chunk ? decode(tailData, dropFirst: tailTruncated, dropLast: false, name: name) : []
        return (head, tail)
    }

    func decode(_ data: Data, dropFirst: Bool, dropLast: Bool, name: String) -> [Line] {
        var parts = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if dropFirst, !parts.isEmpty { parts.removeFirst() }
        if dropLast, !parts.isEmpty { parts.removeLast() }
        let decoder = JSONDecoder()
        var lines: [Line] = []
        var bad = 0
        for part in parts {
            if let line = try? decoder.decode(Line.self, from: Data(part)) { lines.append(line) } else { bad += 1 }
        }
        if bad > 0 { log("skip \(bad) unparsable line(s) in \(name)") }
        return lines
    }
}

/// ISO-8601 with or without fractional seconds. Created per scan because formatters are not Sendable.
struct TimestampParser {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func parse(_ text: String) -> Date? { fractional.date(from: text) ?? plain.date(from: text) }
}
