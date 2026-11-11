import Foundation
import Testing
@testable import MusterCore

@Suite struct ClaudeTranscriptScannerTests {
    let clock = SessionsTestClock()

    /// Writes a synthetic transcript and sets its mtime.
    @discardableResult
    func writeTranscript(
        root: URL, dir: String, id: String, lines: [String], mtime: Date
    ) throws -> URL {
        let d = root.appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let file = d.appendingPathComponent("\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        return file
    }

    func scanner(_ root: URL, log: SessionsTestLog = SessionsTestLog()) -> ClaudeTranscriptScanner {
        ClaudeTranscriptScanner(projectsRoot: root, clock: clock, log: log.sink)
    }

    @Test func infersSessionFromMinimalFields() throws {
        let root = try makeSessionsTempDir(); defer { removeSessionsTempDir(root) }
        let start = clock.now().addingTimeInterval(-600)
        let mtime = clock.now().addingTimeInterval(-20)
        try writeTranscript(root: root, dir: "-tmp-proj", id: "s-1", lines: [
            #"{"type":"mode","mode":"x","sessionId":"s-1"}"#,
            #"{"type":"user","cwd":"/tmp/proj","sessionId":"s-1","timestamp":"\#(sessionsISO(start))","unknown":{"a":1}}"#,
        ], mtime: mtime)

        let sessions = try scanner(root).scan()
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.id == "s-1")
        #expect(s.agent == .claude)
        #expect(s.cwd == "/tmp/proj")
        #expect(abs(s.startedAt.timeIntervalSince(start)) < 1)
        #expect(abs(s.lastActivityAt.timeIntervalSince(mtime)) < 1)
        #expect(s.projectName == "proj")
    }

    @Test func fallsBackToFileNameWhenSessionIdMissing() throws {
        let root = try makeSessionsTempDir(); defer { removeSessionsTempDir(root) }
        try writeTranscript(root: root, dir: "-tmp-a", id: "from-name", lines: [
            #"{"type":"user","cwd":"/tmp/a"}"#
        ], mtime: clock.now())
        #expect(try scanner(root).scan().first?.id == "from-name")
    }

    @Test func skipsUnparsableLinesAndLogs() throws {
        let root = try makeSessionsTempDir(); defer { removeSessionsTempDir(root) }
        let log = SessionsTestLog()
        try writeTranscript(root: root, dir: "-tmp-b", id: "s-2", lines: [
            "not json at all", #"{"broken":"#, #"{"cwd":"/tmp/b","sessionId":"s-2"}"#,
        ], mtime: clock.now())
        let sessions = try scanner(root, log: log).scan()
        #expect(sessions.map(\.cwd) == ["/tmp/b"])
        #expect(log.messages.contains { $0.contains("unparsable") })
        // Log lines carry file names and counts only.
        #expect(!log.messages.contains { $0.contains("not json at all") })
    }

    @Test func skipsFilesWithoutCwdAndOlderThanRetention() throws {
        let root = try makeSessionsTempDir(); defer { removeSessionsTempDir(root) }
        let log = SessionsTestLog()
        try writeTranscript(root: root, dir: "-tmp-c", id: "no-cwd", lines: [#"{"type":"mode"}"#], mtime: clock.now())
        try writeTranscript(root: root, dir: "-tmp-c", id: "old", lines: [#"{"cwd":"/tmp/c"}"#],
                            mtime: clock.now().addingTimeInterval(-SessionPolicy.defaultRetention - 60))
        #expect(try scanner(root, log: log).scan().isEmpty)
        #expect(log.messages.contains { $0.contains("no cwd") })
    }

    @Test func missingRootGivesEmptyList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        #expect(try scanner(root).scan().isEmpty)
    }

    @Test func readsOnlyBoundedChunksOfLargeFiles() throws {
        let root = try makeSessionsTempDir(); defer { removeSessionsTempDir(root) }
        // About 1 MB of synthetic filler lines between a head line and a tail line.
        let filler = #"{"type":"assistant","pad":""# + String(repeating: "x", count: 900) + #""}"#
        var lines = [#"{"cwd":"/tmp/big","sessionId":"big","timestamp":"\#(sessionsISO(clock.now()))"}"#]
        lines += Array(repeating: filler, count: 1200)
        lines.append(#"{"type":"last","sessionId":"big"}"#)
        let file = try writeTranscript(root: root, dir: "-tmp-big", id: "big", lines: lines, mtime: clock.now())
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        #expect(size > 4 * ClaudeTranscriptScanner.chunkSize)

        let s = try #require(try scanner(root).scan().first)
        #expect(s.id == "big")
        #expect(s.cwd == "/tmp/big")
    }

    @Test func newestActivityFirst() throws {
        let root = try makeSessionsTempDir(); defer { removeSessionsTempDir(root) }
        try writeTranscript(root: root, dir: "-tmp-d", id: "older", lines: [#"{"cwd":"/tmp/d"}"#],
                            mtime: clock.now().addingTimeInterval(-500))
        try writeTranscript(root: root, dir: "-tmp-d", id: "newer", lines: [#"{"cwd":"/tmp/d"}"#],
                            mtime: clock.now().addingTimeInterval(-5))
        #expect(try scanner(root).scan().map(\.id) == ["newer", "older"])
    }
}
