import Darwin
import Foundation
import IOKit

public struct TransferRate: Sendable {
    public fileprivate(set) var first: Double = 0
    public fileprivate(set) var second: Double = 0

    fileprivate init() {}
}

public struct TransferCounters: Sendable {
    public let first: UInt64
    public let second: UInt64

    public init(_ first: UInt64, _ second: UInt64) {
        self.first = first
        self.second = second
    }
}

public struct TransferSampler<Key: Hashable> {
    private var previous: [Key: TransferCounters] = [:]
    private var previousTime: TimeInterval?

    public init() {}

    public mutating func sample(_ current: [Key: TransferCounters], time: TimeInterval) -> TransferRate? {
        defer {
            previous = current
            previousTime = time
        }
        guard let previousTime, time > previousTime, time - previousTime <= 15 else { return nil }
        let interval = time - previousTime
        var rate = TransferRate()
        for (key, counters) in current {
            guard let old = previous[key] else { continue }
            if counters.first >= old.first { rate.first += Double(counters.first - old.first) / interval }
            if counters.second >= old.second { rate.second += Double(counters.second - old.second) / interval }
        }
        return rate
    }
}

public struct ProcessReading: Identifiable, Sendable {
    public let id: pid_t
    public let name: String
    public let cpu: Double?
    public let memory: Int64?
    public let memoryIsResident: Bool
}

public struct ProcessReadings: Sendable {
    public let byCPU: [ProcessReading]
    public let byMemory: [ProcessReading]

    public static let empty = ProcessReadings(byCPU: [], byMemory: [])
}

public struct ProcessSampler {
    private struct Counters {
        let start: String
        let cpuTime: Double
    }

    private var previous: [pid_t: Counters] = [:]
    private var previousTime: TimeInterval?

    public init() {}

    public mutating func sample() -> ProcessReadings? {
        // ps can still provide CPU and RSS for processes that deny proc_pid_rusage.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aco", "pid=,time=,pcpu=,lstart=,rss=,comm="]
        process.environment = ["LC_ALL": "C"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return readings(from: String(decoding: data, as: UTF8.self),
                        time: ProcessInfo.processInfo.systemUptime, excluding: process.processIdentifier) { pid in
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            return status == 0 ? Int64(clamping: info.ri_phys_footprint) : nil
        }
    }

    public mutating func readings(
        from output: String, time: TimeInterval, excluding samplerPID: pid_t, memory: (pid_t) -> Int64?
    ) -> ProcessReadings {
        let interval = previousTime.map { time - $0 }
        var current: [pid_t: Counters] = [:]
        let rows = output.split(whereSeparator: \.isNewline).compactMap { line -> ProcessReading? in
            // pid, CPU time, recent CPU, five start-time fields, RSS in KiB, executable name.
            let fields = line.split(maxSplits: 9, whereSeparator: \.isWhitespace)
            guard fields.count == 10, let pid = pid_t(fields[0]), pid > 0, pid != samplerPID else { return nil }
            var cpu = Double(fields[2]).flatMap { $0.isFinite && $0 >= 0 ? $0 / 100 : nil }
            let start = fields[3...7].joined(separator: " ")
            if let cpuTime = Self.seconds(fields[1]) {
                current[pid] = Counters(start: start, cpuTime: cpuTime)
                if let interval, interval > 0, interval <= 15,
                   let old = previous[pid], old.start == start, cpuTime >= old.cpuTime {
                    cpu = (cpuTime - old.cpuTime) / interval
                }
            }
            let name = fields[9].trimmingCharacters(in: .whitespaces)
            let footprint = memory(pid)
            let resident = Int64(fields[8]).flatMap { kib in
                (1...(Int64.max / 1024)).contains(kib) ? kib * 1024 : nil
            }
            return ProcessReading(id: pid, name: name, cpu: cpu, memory: footprint ?? resident,
                                  memoryIsResident: footprint == nil && resident != nil)
        }
        previous = current
        previousTime = time
        let byCPU = rows.filter { $0.cpu != nil }.sorted {
            let first = $0.cpu ?? -1
            let second = $1.cpu ?? -1
            return first == second ? $0.id < $1.id : first > second
        }
        let byMemory = rows.filter { $0.memory != nil }.sorted {
            let first = $0.memory ?? -1
            let second = $1.memory ?? -1
            return first == second ? $0.id < $1.id : first > second
        }
        return ProcessReadings(byCPU: Array(byCPU.prefix(10)), byMemory: Array(byMemory.prefix(10)))
    }

    private static func seconds(_ value: Substring) -> Double? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), minutes >= 0,
              let seconds = Double(parts[1]), (0..<60).contains(seconds) else { return nil }
        return Double(minutes) * 60 + seconds
    }

}

extension SystemSampler {
    public static func networkCounters() -> [UInt16: TransferCounters]? {
        var mib = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        return buffer.withUnsafeBytes { bytes in
            var offset = 0
            var interfaces: [UInt16: TransferCounters] = [:]
            while offset + 4 <= size {
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= size - offset else { break }
                if bytes[offset + 3] == UInt8(RTM_IFINFO2), length >= MemoryLayout<if_msghdr2>.size {
                    let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if message.ifm_flags & Int32(IFF_UP | IFF_RUNNING) == Int32(IFF_UP | IFF_RUNNING),
                       if_indextoname(UInt32(message.ifm_index), &name) != nil,
                       name.starts(with: [101, 110]) { // Ethernet and Wi-Fi BSD names begin with en.
                        interfaces[message.ifm_index] = TransferCounters(message.ifm_data.ifi_obytes, message.ifm_data.ifi_ibytes)
                    }
                }
                offset += length
            }
            return interfaces
        }
    }

    public static func diskCounters() -> [UInt64: TransferCounters]? {
        var devices: [UInt64: TransferCounters] = [:]
        visitServices("IOBlockStorageDriver") { service in
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  let statistics = property("Statistics", service: service) as? [String: NSNumber],
                  let read = statistics["Bytes (Read)"], let write = statistics["Bytes (Write)"] else { return }
            devices[id] = TransferCounters(read.uint64Value, write.uint64Value)
        }
        return devices.isEmpty ? nil : devices
    }

    public static func gpuUsage() -> Double? {
        var usage: Double?
        visitServices("IOAccelerator") { service in
            guard let stats = property("PerformanceStatistics", service: service) as? [String: Any],
                  let number = stats["Device Utilization %"] as? NSNumber
                    ?? stats["GPU Activity(%)"] as? NSNumber
                    ?? stats["Renderer Utilization %"] as? NSNumber else { return }
            let fraction = number.doubleValue / 100
            guard fraction.isFinite, (0...1).contains(fraction) else { return }
            usage = max(usage ?? 0, fraction)
        }
        return usage
    }

    public static func swapUsed() -> Int64? {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return nil }
        return Int64(clamping: swap.xsu_used)
    }

    public static func batteryWatts() -> Double? {
        var watts: Double?
        visitServices("AppleSmartBattery") { service in
            guard let voltage = property("Voltage", service: service) as? NSNumber,
                  let current = property("InstantAmperage", service: service) as? NSNumber
                    ?? property("Amperage", service: service) as? NSNumber else { return }
            let value = voltage.doubleValue * Double(current.int64Value) / 1_000_000
            if value.isFinite, abs(value) < 500 { watts = value }
        }
        return watts
    }

    private static func visitServices(_ type: String, _ visit: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(type), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            visit(service)
            IOObjectRelease(service)
        }
    }

    private static func property(_ name: String, service: io_service_t) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
