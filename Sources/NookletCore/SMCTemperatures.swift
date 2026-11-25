import IOKit

/// The SMC has model-specific sensor keys. Only use keys known to identify a CPU or GPU sensor.
public enum SMCTemperatures {
    private struct Message {
        var key: UInt32 = 0
        var version: (UInt32, UInt16) = (0, 0) // Six version bytes.
        var limits: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
        var size: UInt32 = 0
        var type: UInt32 = 0
        var attributes: UInt32 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var index: UInt32 = 0
        var bytes: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0)

        func send(to connection: io_connect_t) -> Message? {
            var input = self
            var output = Message()
            var size = MemoryLayout<Message>.stride
            let status = IOConnectCallStructMethod(connection, 2, &input, size, &output, &size)
            return status == KERN_SUCCESS && output.result == 0 ? output : nil
        }
    }

    public static func read(chip: String, cpu: Bool, gpu: Bool) -> (cpu: Double?, gpu: Double?) {
        let cpuKeys: [String]
        let gpuKeys: [String]
        if chip.hasPrefix("Apple M2") {
            cpuKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp1h", "Tp1t", "Tp1p", "Tp1l"]
            gpuKeys = ["Tg0f", "Tg0j"]
        } else if chip.hasPrefix("Apple M1") {
            cpuKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Te05", "Te0L", "Te0P", "Te0S"]
            gpuKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        } else if chip.hasPrefix("Apple M3") {
            cpuKeys = ["Tf04", "Tf09", "Tf0A", "Tf0B", "Te05", "Te0L", "Te0P", "Te0S"]
            gpuKeys = ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        } else if chip.hasPrefix("Intel") {
            cpuKeys = ["TC0D"]
            gpuKeys = ["TG0D"]
        } else {
            return (nil, nil)
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return (nil, nil) }
        defer { IOServiceClose(connection) }

        func average(_ keys: [String]) -> Double? {
            let values = keys.compactMap { temperature($0, connection: connection) }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return (cpu ? average(cpuKeys) : nil, gpu ? average(gpuKeys) : nil)
    }

    private static func temperature(_ key: String, connection: io_connect_t) -> Double? {
        var request = Message()
        request.key = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
        request.command = 9 // Read key metadata.
        guard let metadata = request.send(to: connection), (2...4).contains(metadata.size) else { return nil }
        request.size = metadata.size
        request.command = 5 // Read value bytes.
        guard let response = request.send(to: connection) else { return nil }

        let value: Double
        switch (metadata.type, metadata.size) {
        case (0x666C7420, 4): // flt
            value = Double(Float(bitPattern: UInt32(littleEndian: response.bytes.0)))
        case (0x73703738, 2): // sp78
            let bits = UInt16(truncatingIfNeeded: UInt32(littleEndian: response.bytes.0))
            value = Double(Int16(bitPattern: UInt16(bigEndian: bits))) / 256
        default:
            return nil
        }
        return value.isFinite && (1...125).contains(value) ? value : nil
    }
}
