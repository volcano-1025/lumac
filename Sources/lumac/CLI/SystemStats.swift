import Foundation
import Darwin

/// Live CPU / memory / disk figures read straight from the kernel.
///
/// `mo status` is spawned fresh every poll, so anything it derives from a delta
/// (CPU load, throughput) or simply samples slowly comes back stale — the same
/// reason network rates and GPU load are read natively. These are cheap syscalls
/// safe to call every second.
enum SystemStats {

    // MARK: - CPU

    /// Cumulative CPU tick counters since boot (they wrap; diff with `&-`).
    struct CPUTicks { var user: UInt32; var system: UInt32; var idle: UInt32; var nice: UInt32 }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3)
    }

    /// Busy percentage between two tick samples, or nil if the window is empty.
    static func cpuUsage(from prev: CPUTicks, to now: CPUTicks) -> Double? {
        let user = Double(now.user &- prev.user)
        let system = Double(now.system &- prev.system)
        let idle = Double(now.idle &- prev.idle)
        let nice = Double(now.nice &- prev.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return (user + system + nice) / total * 100
    }

    // MARK: - Memory

    /// Used bytes = App Memory + Wired + Compressed, the same figure Activity
    /// Monitor and Stats report. App Memory is the anonymous (internal) pages
    /// minus the purgeable ones the system can reclaim on demand; total from the
    /// hardware. (Counting only the `active` list, as an earlier version did,
    /// dropped the inactive anonymous pages and read several points low.)
    static func memory() -> (used: Int64, total: Int64, percent: Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Int64(pageSize)

        let appMemory = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let used = (appMemory + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        return (used, total, Double(used) / Double(total) * 100)
    }

    // MARK: - Disk

    static func disk() -> (used: Int64, total: Int64, percent: Double)? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
            let total = values.volumeTotalCapacity else { return nil }

        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        let used = Int64(total) - available
        guard total > 0 else { return nil }
        return (used, Int64(total), Double(used) / Double(total) * 100)
    }
}
