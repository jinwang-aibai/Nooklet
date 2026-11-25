import Combine
import Darwin
import Foundation
import Metal
import NookletCore

struct MetricReading: Sendable {
    let value: String
    let detail: String
    var badge: String? = nil
    var fields: [StatusField: String] = [:]
    var point: Double? = nil
    var secondaryPoint: Double? = nil
    var history: [Double] = []
    var secondaryHistory: [Double] = []
}

struct StatusSnapshot: Sendable {
    var readings: [StatusMetric: MetricReading] = [:]
    var processes: ProcessReadings?
}

@MainActor
final class StatusSampler: ObservableObject {
    private static let backgroundInterval: TimeInterval = 5
    private let probe = StatusProbe()
    private var timer: Timer?
    private var sampling = false
    private var metrics: Set<StatusMetric> = []
    private var backgroundMetrics: Set<StatusMetric> = []
    private var lastBackgroundSample: TimeInterval?
    private var interval: TimeInterval = 0
    private var revision = 0
    private var dashboardVisible = false
    @Published private(set) var snapshot = StatusSnapshot()
    var onUpdate: (() -> Void)?

    func configure(metrics: Set<StatusMetric>, backgroundMetrics: Set<StatusMetric> = [],
                   interval: TimeInterval, dashboardVisible: Bool) {
        let backgroundMetrics = backgroundMetrics.subtracting(metrics)
        guard self.metrics != metrics || self.backgroundMetrics != backgroundMetrics
                || self.interval != interval || self.dashboardVisible != dashboardVisible else { return }
        timer?.invalidate()
        timer = nil
        self.metrics = metrics
        if self.backgroundMetrics != backgroundMetrics { lastBackgroundSample = nil }
        self.backgroundMetrics = backgroundMetrics
        self.interval = interval
        self.dashboardVisible = dashboardVisible
        revision += 1
        let enabled = metrics.union(backgroundMetrics)
        snapshot.readings = snapshot.readings.filter { enabled.contains($0.key) }
        if !enabled.contains(.processes) { snapshot.processes = nil }
        guard !enabled.isEmpty else { return }
        tick()
        let cadence = metrics.isEmpty ? Self.backgroundInterval : interval
        let timer = Timer(timeInterval: cadence, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = cadence * 0.12
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard !sampling else { return }
        let enabled = metrics.union(backgroundMetrics)
        let time = ProcessInfo.processInfo.systemUptime
        var due = metrics
        if !backgroundMetrics.isEmpty, lastBackgroundSample.map({ time - $0 >= Self.backgroundInterval }) ?? true {
            due.formUnion(backgroundMetrics)
            lastBackgroundSample = time
        }
        guard !due.isEmpty else { return }
        sampling = true
        let revision = self.revision
        let dashboardVisible = self.dashboardVisible
        Task {
            let sample = await probe.sample(due, enabled: enabled, dashboardVisible: dashboardVisible)
            sampling = false
            guard self.revision == revision else {
                lastBackgroundSample = nil
                tick()
                return
            }
            var next = snapshot
            for (metric, var reading) in sample.readings {
                let previous = snapshot.readings[metric]
                reading.history = Self.append(reading.point, to: previous?.history ?? [])
                reading.secondaryHistory = Self.append(reading.secondaryPoint, to: previous?.secondaryHistory ?? [])
                next.readings[metric] = reading
            }
            next.processes = sample.processes
            snapshot = next
            onUpdate?()
        }
    }

    private static func append(_ point: Double?, to history: [Double]) -> [Double] {
        guard let point else { return history }
        return Array(history.suffix(35)) + [point]
    }
}

private actor StatusProbe {
    private var system = SystemSampler()
    private var network = TransferSampler<UInt16>()
    private var disk = TransferSampler<UInt64>()
    private var processes = ProcessSampler()
    private var lastProcesses: TimeInterval?
    private var processReadings: ProcessReadings?
    private var diskCapacity: Capacity?
    private var lastDiskCapacity: TimeInterval?
    private var lastBattery: TimeInterval?
    private lazy var gpuName = MTLCreateSystemDefaultDevice()?.name
    private lazy var chipName: String = {
        var name = [CChar](repeating: 0, count: 128)
        var size = name.count
        guard sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0) == 0 else { return "" }
        return String(decoding: name.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }()
    private var lastTemperatures: TimeInterval?
    private var temperatures: (cpu: Double?, gpu: Double?) = (nil, nil)

    func sample(_ metrics: Set<StatusMetric>, enabled: Set<StatusMetric>, dashboardVisible: Bool) -> StatusSnapshot {
        let time = ProcessInfo.processInfo.systemUptime
        var result = StatusSnapshot()
        if dashboardVisible, metrics.contains(.cpu) || metrics.contains(.gpu) {
            if lastTemperatures.map({ time - $0 >= 4 }) ?? true {
                temperatures = SMCTemperatures.read(chip: chipName, cpu: metrics.contains(.cpu), gpu: metrics.contains(.gpu))
                lastTemperatures = time
            }
        } else {
            temperatures = (nil, nil)
            lastTemperatures = nil
        }
        if metrics.contains(.cpu) || metrics.contains(.memory) {
            let sample = system.sample()
            if metrics.contains(.cpu) {
                var load = 0.0
                let loadText = getloadavg(&load, 1) == 1 ? String(format: L10n.text("负载 %.2f"), load) : L10n.text("负载 —")
                result.readings[.cpu] = utilization(sample.cpuUsage, detail: loadText, badge: temperatureLabel(temperatures.cpu))
            }
            if metrics.contains(.memory), let memory = sample.memory {
                let fraction = Double(memory.used) / Double(memory.total)
                let used = statusSize(memory.used, style: .memory)
                let swap = SystemSampler.swapUsed().map { statusSize($0, style: .memory) } ?? "—"
                let value = statusPercentage(fraction)
                result.readings[.memory] = MetricReading(value: value, detail: L10n.text("已用 %@ · 交换 %@", used, swap),
                    badge: statusSize(memory.total, style: .memory), fields: [.usage: value, .memoryUsed: used, .swap: swap],
                    point: fraction)
            }
        }
        if metrics.contains(.gpu) {
            let usage = SystemSampler.gpuUsage()
            let name = gpuName.map { $0.hasPrefix("Apple ") ? String($0.dropFirst(6)) : $0 }
            result.readings[.gpu] = utilization(usage, detail: usage == nil ? L10n.text("使用率不可用") : name ?? L10n.text("图形处理器"),
                                               badge: temperatureLabel(temperatures.gpu))
        }
        if metrics.contains(.network) {
            let rate = SystemSampler.networkCounters().flatMap { network.sample($0, time: time) }
            let upload = statusRate(rate?.first)
            let download = statusRate(rate?.second)
            result.readings[.network] = MetricReading(value: download, detail: "↑ \(upload)   ↓ \(download)",
                badge: L10n.text("下载"), fields: [.upload: upload, .download: download], point: rate?.second, secondaryPoint: rate?.first)
        } else if !enabled.contains(.network) {
            network = TransferSampler()
        }
        if metrics.contains(.disk) {
            if lastDiskCapacity.map({ time - $0 >= 8 }) ?? true {
                diskCapacity = SystemSampler.diskCapacity(at: FileManager.default.homeDirectoryForCurrentUser)
                lastDiskCapacity = time
            }
            let rate = SystemSampler.diskCounters().flatMap { disk.sample($0, time: time) }
            let free = diskCapacity.map { capacity in
                let bytes = capacity.total - capacity.used
                return bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000) : statusSize(bytes)
            } ?? "—"
            let read = statusRate(rate?.first)
            let write = statusRate(rate?.second)
            let total = diskCapacity.map { String(format: "%.0f GB", Double($0.total) / 1_000_000_000) }
            result.readings[.disk] = MetricReading(value: free, detail: L10n.text("读 %@   写 %@", read, write), badge: total,
                fields: [.freeSpace: free, .read: read, .write: write], point: rate?.first, secondaryPoint: rate?.second)
        } else if !enabled.contains(.disk) {
            disk = TransferSampler()
        }
        if metrics.contains(.battery) {
            if lastBattery.map({ time - $0 >= 5 }) ?? true {
                result.readings[.battery] = readBattery()
                lastBattery = time
            }
        } else if !enabled.contains(.battery) {
            lastBattery = nil
        }
        if metrics.contains(.thermal) {
            let state = thermalLabel()
            result.readings[.thermal] = MetricReading(value: state, detail: L10n.text("macOS 热状态"), fields: [.thermalState: state])
        }
        if enabled.contains(.processes) {
            let processInterval = dashboardVisible ? 2.7 : 10.0
            if metrics.contains(.processes), lastProcesses.map({ time - $0 >= processInterval }) ?? true {
                processReadings = processes.sample() ?? ProcessReadings.empty
                lastProcesses = time
            }
            result.processes = processReadings
        } else {
            if lastProcesses != nil { processes = ProcessSampler() }
            lastProcesses = nil
            processReadings = nil
        }
        return result
    }

    private func temperatureLabel(_ value: Double?) -> String? {
        value.map { String(format: "%.0f°C", $0) }
    }

    private func utilization(_ fraction: Double?, detail: String, badge: String? = nil) -> MetricReading {
        let value = fraction.map(statusPercentage) ?? "—"
        return MetricReading(value: value, detail: detail, badge: badge, fields: [.usage: value], point: fraction)
    }

    private func readBattery() -> MetricReading {
        guard let battery = SystemSampler.battery() else {
            return MetricReading(value: "—", detail: L10n.text("未检测到电池"))
        }
        let value = "\(battery.percent)%"
        let source = battery.onACPower ? L10n.text("已接电源") : L10n.text("使用电池")
        let power = SystemSampler.batteryWatts().map { String(format: "%.1f W", abs($0)) }
        return MetricReading(value: value, detail: [source, power].compactMap { $0 }.joined(separator: " · "),
            fields: [.batteryLevel: value, .powerSource: source, .batteryPower: power ?? "—"], point: Double(battery.percent) / 100)
    }
}

func statusSize(_ bytes: Int64, style: ByteCountFormatter.CountStyle = .file) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: style)
}

func statusRate(_ bytes: Double?) -> String {
    guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
    for (scale, unit) in [(1_000_000_000.0, "GB/s"), (1_000_000.0, "MB/s"), (1_000.0, "KB/s")] where bytes >= scale {
        let value = bytes / scale
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, unit)
    }
    return "\(Int(bytes)) B/s"
}

func statusPercentage(_ ratio: Double) -> String { String(format: "%.0f%%", ratio * 100) }

func thermalLabel() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: L10n.text("正常")
    case .fair: L10n.text("略高")
    case .serious: L10n.text("较高")
    case .critical: L10n.text("过热")
    @unknown default: L10n.text("未知")
    }
}
