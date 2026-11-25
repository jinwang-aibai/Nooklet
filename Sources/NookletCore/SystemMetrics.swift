import Darwin
import Foundation
import IOKit.ps

public struct Capacity: Sendable {
    public let used: Int64
    public let total: Int64
}

public struct SystemSample: Sendable {
    public let cpuUsage: Double?
    public let memory: Capacity?
}

public struct BatterySample: Sendable {
    public let percent: Int
    public let onACPower: Bool
}

/// Callers control sampling. The sampler creates no timers or background work.
public struct SystemSampler {
    private var previousTicks: (UInt32, UInt32, UInt32, UInt32)?
    private let memoryTotal = Int64(clamping: ProcessInfo.processInfo.physicalMemory)

    public init() {}

    public mutating func sample() -> SystemSample {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        return SystemSample(cpuUsage: cpuUsage(host: host), memory: memoryUsage(host: host))
    }

    private mutating func cpuUsage(host: host_t) -> Double? {
        var load = host_cpu_load_info()
        let wordCount = MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(wordCount)
        let status = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: wordCount) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let current = load.cpu_ticks // user, system, idle, nice
        defer { previousTicks = current }
        guard let previous = previousTicks else { return nil }
        let active = UInt64(current.0 &- previous.0)
            + UInt64(current.1 &- previous.1)
            + UInt64(current.3 &- previous.3)
        let total = active + UInt64(current.2 &- previous.2)
        return total > 0 ? Double(active) / Double(total) : nil
    }

    private func memoryUsage(host: host_t) -> Capacity? {
        var statistics = vm_statistics64()
        let wordCount = MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(wordCount)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: wordCount) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS, memoryTotal > 0 else { return nil }
        let appPages = max(0, Int64(statistics.internal_page_count) - Int64(statistics.purgeable_count))
        let pages = appPages + Int64(statistics.wire_count) + Int64(statistics.compressor_page_count)
        return Capacity(used: min(memoryTotal, pages * Int64(getpagesize())), total: memoryTotal)
    }

    public static func diskCapacity(at url: URL) -> Capacity? {
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity,
              total > 0 else { return nil }
        return Capacity(used: Int64(max(0, total - available)), total: Int64(total))
    }

    public static func battery() -> BatterySample? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let entry = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  entry[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = entry[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = entry[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            let percent = Int((100 * Double(current) / Double(maximum)).rounded())
            return BatterySample(percent: min(100, max(0, percent)),
                                 onACPower: entry[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}
