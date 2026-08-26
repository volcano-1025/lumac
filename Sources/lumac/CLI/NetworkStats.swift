import Foundation

/// Per-interface byte counters read straight from the kernel.
///
/// `mo status` is run as a fresh process on every poll, so the CLI has no prior
/// sample to diff against and its throughput numbers come back near-zero — the
/// same reason GPU utilisation is read from IOKit rather than the CLI. The app
/// samples the interface counters itself and computes the rate across polls.
enum NetworkStats {
    struct Counters {
        /// 32-bit cumulative byte counters, as `getifaddrs` reports them. They
        /// wrap at 4 GiB; deltas use `&-` so a single wrap between two samples
        /// still yields the correct positive difference.
        var rx: UInt32
        var tx: UInt32
    }

    /// Cumulative in/out bytes for the physical interfaces (Wi-Fi / Ethernet /
    /// cellular). Virtual and loopback interfaces are skipped — on a VPN the
    /// encrypted traffic still shows up on the underlying `en` interface.
    static func sample() -> [String: Counters] {
        var result: [String: Counters] = [:]

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }

            guard let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }

            guard let dataPtr = entry.pointee.ifa_data else { continue }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            result[name] = Counters(rx: data.ifi_ibytes, tx: data.ifi_obytes)
        }
        return result
    }
}
