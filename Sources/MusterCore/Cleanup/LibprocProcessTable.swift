import Foundation
import Darwin

/// 基于 libproc 的真实进程表（只读）。
public struct LibprocProcessTable: ProcessTable {
    public init() {}

    public func allPIDs() -> [Int32] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let size = MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: Int(needed) / size + 64)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * size))
        guard got > 0 else { return [] }
        return pids.prefix(Int(got) / size).filter { $0 > 0 }
    }

    public func record(for pid: Int32) -> ProcessRecord? {
        guard pid > 0 else { return nil }
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }

        let start = Date(timeIntervalSince1970:
            TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
        return ProcessRecord(
            pid: pid, ppid: Int32(bitPattern: bsd.pbi_ppid), startTime: start,
            cwd: cwd(of: pid), name: name(from: bsd), executablePath: path(of: pid),
            cpuTimeSeconds: cpuSeconds(of: pid))
    }

    private func name(from bsd: proc_bsdinfo) -> String? {
        var info = bsd
        return withUnsafePointer(to: &info.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                let s = String(cString: $0)
                return s.isEmpty ? nil : s
            }
        }
    }

    private func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                let s = String(cString: $0)
                return s.isEmpty ? nil : s
            }
        }
    }

    private func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }

    private func cpuSeconds(of pid: Int32) -> Double? {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(task.pti_total_user &+ task.pti_total_system)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}
