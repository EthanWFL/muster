import Foundation
@testable import MusterCore

/// Mutable clock for tests. Prefixed names avoid clashes with helpers from other test directories.
final class SessionsTestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// Probe whose answers are set by the test.
final class SessionsTestProbe: ProcessProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var dead: Set<Int32> = []

    func kill(_ pid: Int32) { lock.lock(); dead.insert(pid); lock.unlock() }

    func isAlive(pid: Int32, startTime: Date?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !dead.contains(pid)
    }
}

/// Collects diagnostic messages.
final class SessionsTestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    var sink: DiagnosticSink { { [self] message in lock.lock(); items.append(message); lock.unlock() } }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

func makeSessionsTempDir(_ label: String = "sessions") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("muster-test-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func removeSessionsTempDir(_ url: URL) { try? FileManager.default.removeItem(at: url) }

func sessionsISO(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}
