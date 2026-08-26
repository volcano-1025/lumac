import Foundation
import IOKit

struct GPUSample {
    /// 0...100. Nil when no accelerator exposes the statistic.
    var utilization: Double?
    /// Bytes currently resident in GPU-visible memory.
    var memoryInUse: Int64?
}

/// Reads GPU utilisation from IOKit.
///
/// `mo status` reports -1 for GPU usage on Apple Silicon, but the figure is
/// available without elevated privileges: the IOAccelerator service publishes a
/// `PerformanceStatistics` dictionary containing "Device Utilization %". This is
/// the same source Activity Monitor's GPU history and the open-source system
/// monitors read.
enum GPUStats {

    static func sample() -> GPUSample {
        // IOAccelerator is the generic class; AGXAccelerator is its Apple
        // Silicon subclass. Matching the generic one covers both, and Intel Macs
        // with discrete GPUs publish the same keys.
        guard let matching = IOServiceMatching("IOAccelerator") else { return GPUSample() }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return GPUSample()
        }
        defer { IOObjectRelease(iterator) }

        var best = GPUSample()
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  let stats = properties["PerformanceStatistics"] as? [String: Any] else { continue }

            let utilization = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
                ?? (stats["Renderer Utilization %"] as? NSNumber)?.doubleValue
            let memory = (stats["In use system memory"] as? NSNumber)?.int64Value

            // A machine can expose several accelerators; report the busiest.
            if let utilization, utilization >= (best.utilization ?? -1) {
                best.utilization = utilization
                best.memoryInUse = memory
            } else if best.utilization == nil {
                best.memoryInUse = memory ?? best.memoryInUse
            }
        }
        return best
    }
}
