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

/// Infers sessions from JSONL transcripts `depth` levels below `projectsRoot`:
/// Claude `projects/<cwd>/<id>.jsonl` (2), Pi `sessions/<cwd>/<ts>_<id>.jsonl` (2),
/// Codex `sessions/Y/M/D/rollout-*.jsonl` (4). Gemini, Cursor, OpenCode and DeepSeek Harness
/// use other layouts or compression and are not scanned.
///
/// Only the head and the tail of each file are read (bounded chunks); a transcript is never
/// loaded whole and no conversation text is kept. Only `sessionId`, `cwd` and `timestamp`
/// are decoded from each line (Codex and Pi keep them in their first `session_meta` / `session`
/// line); every other field is ignored.
public struct TranscriptScanner: Sendable {
    /// Bytes read from the start and from the end of each file.
    public static let chunkSize = 64 * 1024

    public let agent: AgentKind
    public let depth: Int
    public let projectsRoot: URL
    public let clock: Clock
    public let retention: TimeInterval
    public let log: DiagnosticSink

    public init(
        agent: AgentKind = .claude, depth: Int = 2,
        projectsRoot: URL, clock: Clock = SystemClock(),
        retention: TimeInterval = SessionPolicy.defaultRetention,
        log: @escaping DiagnosticSink = Diagnostics.default
    ) {
        self.agent = agent
        self.depth = depth
        self.projectsRoot = projectsRoot
        self.clock = clock
        self.retention = retention
        self.log = log
    }

    /// The only fields we depend on.
    struct Line: Decodable {
        var type: String?
        var sessionId: String?
        var id: String?
        var cwd: String?
        var timestamp: String?
        var payload: Payload?
        struct Payload: Decodable { var id: String?; var cwd: String? }

        var sessionID: String? {
            sessionId ?? (type == "session" ? id : nil) ?? (type == "session_meta" ? payload?.id : nil)
        }
        var workingDirectory: String? { cwd ?? (type == "session_meta" ? payload?.cwd : nil) }
    }

    public func scan() throws -> [Session] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsRoot.path) else { return [] }
        let cutoff = clock.now().addingTimeInterval(-retention)
        var result: [Session] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = fm.enumerator(at: projectsRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        // shortcut: walks the whole tree each scan, upgrade if Codex's per-day dirs get too many
        while let file = files?.nextObject() as? URL {
            try Task.checkCancellation()
            guard files?.level == depth, file.pathExtension == "jsonl",
                  let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, let mtime = values.contentModificationDate,
                  mtime >= cutoff else { continue }
            if let session = inspect(file: file, mtime: mtime) { result.append(session) }
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
        let id = all.compactMap(\.sessionID).first ?? stem
        guard let cwd = head.compactMap(\.workingDirectory).first ?? tail.compactMap(\.workingDirectory).first else {
            log("skip \(name): no cwd in head or tail")
            return nil
        }
        let parser = TimestampParser()
        let started = head.compactMap { $0.timestamp.flatMap(parser.parse) }.first ?? mtime
        return Session(id: id, agent: agent, cwd: cwd, startedAt: min(started, mtime),
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
