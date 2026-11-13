import Foundation
import Testing
@testable import MusterCore

@Suite struct TranscriptScannerTests {
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

    func scanner(_ root: URL, log: SessionsTestLog = SessionsTestLog()) -> TranscriptScanner {
        TranscriptScanner(projectsRoot: root, clock: clock, log: log.sink)
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
        #expect(size > 4 * TranscriptScanner.chunkSize)

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

    @Test func readsCodexSessionMetaFourLevelsDeep() throws {
        let root = try makeSessionsTempDir(); defer { removeSessionsTempDir(root) }
        try writeTranscript(root: root, dir: "2026/10/15", id: "rollout-x", lines: [
            #"{"type":"session_meta","payload":{"id":"codex-1","cwd":"/tmp/cx","other":{"id":"no"}}}"#,
            #"{"type":"response_item","payload":{"id":"item-9"}}"#,
        ], mtime: clock.now())
        // a file at the wrong depth is ignored
        try writeTranscript(root: root, dir: "2026", id: "stray", lines: [#"{"cwd":"/tmp/stray"}"#], mtime: clock.now())

        let found = try TranscriptScanner(agent: .codex, depth: 4, projectsRoot: root, clock: clock).scan()
        #expect(found.map(\.id) == ["codex-1"])
        #expect(found.first?.cwd == "/tmp/cx")
        #expect(found.first?.agent == .codex)
    }

    @Test func readsPiSessionHeader() throws {
        let root = try makeSessionsTempDir(); defer { removeSessionsTempDir(root) }
        try writeTranscript(root: root, dir: "--tmp-pi--", id: "2026_pi-1", lines: [
            #"{"type":"session","id":"pi-1","cwd":"/tmp/pi"}"#,
            #"{"type":"model_change","id":"4661de35","parentId":null}"#,
        ], mtime: clock.now())
        let found = try TranscriptScanner(agent: .pi, projectsRoot: root, clock: clock).scan()
        #expect(found.map(\.id) == ["pi-1"])
        #expect(found.first?.cwd == "/tmp/pi")
    }
}
