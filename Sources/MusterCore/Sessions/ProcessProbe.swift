import Foundation
import Darwin

/// Asks whether the process behind a session is still running.
/// Injected so the state machine can be tested without real processes.
public protocol ProcessProbe: Sendable {
    /// `startTime` (when known) guards against PID reuse: a live process with a
    /// different start time is treated as "not the same process".
    func isAlive(pid: Int32, startTime: Date?) -> Bool
}

public struct SystemProcessProbe: ProcessProbe {
    /// Allowed difference between recorded and observed process start time.
    public static let startTimeTolerance: TimeInterval = 2

    public init() {}

    public func isAlive(pid: Int32, startTime: Date?) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) != 0 && errno == ESRCH { return false }
        guard let expected = startTime else { return true }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            // Alive but not inspectable (permissions): cannot disprove it.
            return true
        }
        let started = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return abs(started - expected.timeIntervalSince1970) <= Self.startTimeTolerance
    }
}
