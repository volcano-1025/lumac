import Foundation

/// Decoded `mo status` output. Field names mirror the CLI's JSON exactly.
/// Everything is optional-tolerant: the CLI omits sections on machines that lack
/// the hardware (no battery on a Mac mini, no discrete GPU, and so on).
struct StatusSnapshot: Decodable {
    var collectedAt: String?
    var host: String?
    var uptime: String?
    var procs: Int?
    var hardware: Hardware?
    var healthScore: Int?
    var healthScoreMsg: String?
    var cpu: CPU?
    var gpu: [GPU]?
    var memory: Memory?
    var disks: [Disk]?
    var trashSize: Int64?
    var network: [Interface]?
    var batteries: [Battery]?
    var thermal: Thermal?
    var bluetooth: [BTDevice]?
    var topProcesses: [Proc]?

    struct Hardware: Decodable {
        var model: String?
        var cpuModel: String?
        var totalRam: String?
        var diskSize: String?
        var osVersion: String?
    }

    struct CPU: Decodable {
        var usage: Double?
        var perCore: [Double]?
        var load1: Double?
        var coreCount: Int?
        var pCoreCount: Int?
        var eCoreCount: Int?
    }

    struct GPU: Decodable {
        var name: String?
        /// -1 when the CLI cannot read utilisation (common on Apple Silicon).
        var usage: Double?
        var coreCount: Int?
    }

    struct Memory: Decodable {
        var used: Int64?
        var total: Int64?
        var usedPercent: Double?
        var swapUsed: Int64?
        var cached: Int64?
        var pressure: String?
    }

    struct Disk: Decodable {
        var mount: String?
        var used: Int64?
        var total: Int64?
        var usedPercent: Double?
        var external: Bool?
        var purgeable: Int64?
    }

    struct Interface: Decodable {
        var name: String?
        var rxRateMbs: Double?
        var txRateMbs: Double?
        var ip: String?
    }

    struct Battery: Decodable {
        var percent: Int?
        /// "AC" while plugged in, otherwise discharging.
        var status: String?
        var timeLeft: String?
        var health: String?
        var cycleCount: Int?
        /// Maximum capacity as a percentage of design capacity.
        var capacity: Int?
    }

    struct Thermal: Decodable {
        var cpuTemp: Double?
        var batteryTemp: Double?
        var fanSpeed: Int?
        var systemPower: Double?
        var adapterPower: Double?
    }

    struct BTDevice: Decodable {
        var name: String?
        var connected: Bool?
        /// Free text, e.g. "Right Battery Level: 100%" — parsed by `batteryPercent`.
        var battery: String?

        /// First percentage found in the free-text battery field.
        var batteryPercent: Int? {
            guard let battery, !battery.isEmpty else { return nil }
            let digits = battery.split(whereSeparator: { !$0.isNumber })
            guard let first = digits.first, let value = Int(first), (0...100).contains(value) else { return nil }
            return value
        }
    }

    struct Proc: Decodable, Identifiable {
        var pid: Int
        var name: String?
        var command: String?
        var cpu: Double?
        /// Percentage of physical memory.
        var memory: Double?
        var memoryBytes: Int64?

        var id: Int { pid }
    }

    /// The boot volume, which is what the overview card reports on.
    var primaryDisk: Disk? { disks?.first(where: { $0.mount == "/" }) ?? disks?.first }

    /// The active interface, chosen as the one currently moving the most traffic.
    var primaryInterface: Interface? {
        network?.max(by: { ($0.rxRateMbs ?? 0) + ($0.txRateMbs ?? 0) < ($1.rxRateMbs ?? 0) + ($1.txRateMbs ?? 0) })
    }
}
