import Darwin
import Foundation

/// One running process, as seen through libproc. Command-line arguments are deliberately never read: they can contain
/// secrets, and Half Lid never needs them.
public struct ProcessEntry: Sendable, Equatable {
    public var pid: Int32
    public var parentPid: Int32
    public var name: String
    public var path: String
    /// Cumulative CPU time (user + system) in nanoseconds.
    public var cpuNanoseconds: UInt64

    public init(pid: Int32, parentPid: Int32, name: String, path: String, cpuNanoseconds: UInt64) {
        self.pid = pid
        self.parentPid = parentPid
        self.name = name
        self.path = path
        self.cpuNanoseconds = cpuNanoseconds
    }
}

public enum ProcessProbe {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// Snapshot of all processes the current user is allowed to inspect (others are skipped silently).
    public static func snapshot() -> [ProcessEntry] {
        let expected = Int(proc_listallpids(nil, 0))
        guard expected > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: expected + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }

        var result: [ProcessEntry] = []
        result.reserveCapacity(count)
        for pid in pids.prefix(count) where pid > 0 {
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }

            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            var cpu: UInt64 = 0
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize {
                cpu = toNanoseconds(task.pti_total_user &+ task.pti_total_system)
            }
            result.append(ProcessEntry(
                pid: pid,
                parentPid: Int32(bitPattern: bsd.pbi_ppid),
                name: string(from: { proc_name(pid, $0, UInt32($1)) }, capacity: 256),
                path: string(from: { proc_pidpath(pid, $0, UInt32($1)) }, capacity: 4096),
                cpuNanoseconds: cpu
            ))
        }
        return result
    }

    /// Process-table ticks to nanoseconds. On Apple Silicon the ticks are mach absolute time units, not nanoseconds.
    static func toNanoseconds(_ ticks: UInt64) -> UInt64 {
        let (high, low) = ticks.multipliedFullWidth(by: timebase.numer)
        return timebase.denom.dividingFullWidth((high, low)).quotient
    }

    private static func string(from fill: (UnsafeMutableRawPointer, Int32) -> Int32, capacity: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: capacity)
        let written = buffer.withUnsafeMutableBytes { fill($0.baseAddress!, Int32(capacity)) }
        guard written > 0 else { return "" }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
