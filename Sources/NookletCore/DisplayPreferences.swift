import Foundation

public enum StatusMetric: String, Codable, CaseIterable, Sendable {
    case cpu, gpu, network, disk, memory, battery, processes, thermal

    public static let menuMetrics = allCases.filter { $0 != .processes }
}

public enum StatusField: String, Codable, CaseIterable, Sendable {
    case usage, upload, download, freeSpace, read, write, memoryUsed, swap, batteryLevel, powerSource, batteryPower, thermalState
}

public enum StatusStyle: String, Codable, CaseIterable, Sendable {
    case detailed, compact, minimal
}

public enum StatusArrangement: String, Codable, CaseIterable, Sendable {
    case automatic, horizontal, vertical
}

public enum ProcessSorting: String, Codable, CaseIterable, Sendable {
    case cpu, memory
}

public struct StatusMenuOptions: Codable, Equatable, Sendable {
    public var fields: Set<StatusField>
    public var style: StatusStyle
    public var arrangement: StatusArrangement = .automatic

    public init(metric: StatusMetric) {
        self.fields = Set(metric.defaultFields)
        self.style = metric == .network ? .minimal : .detailed
    }
}

extension StatusMetric {
    public var menuFields: [StatusField] {
        switch self {
        case .cpu, .gpu: [.usage]
        case .network: [.upload, .download]
        case .disk: [.freeSpace, .read, .write]
        case .memory: [.usage, .memoryUsed, .swap]
        case .battery: [.batteryLevel, .batteryPower, .powerSource]
        case .thermal: [.thermalState]
        case .processes: []
        }
    }

    fileprivate var defaultFields: [StatusField] {
        switch self {
        case .disk: [.read, .write]
        case .memory: [.usage, .memoryUsed]
        default: menuFields
        }
    }
}

public struct DisplayPreferences: Codable, Equatable, Sendable {
    public var menu: Set<StatusMetric> = [.cpu, .gpu, .disk, .memory, .processes]
    public var panelOrder: [StatusMetric] = [.cpu, .gpu, .disk, .memory, .processes, .network, .battery, .thermal]
    public var calendarVisible = true
    public var processLimit = 3
    public var processSorting: ProcessSorting = .cpu
    public var memoryShowsSwap = true

    public var liveMenuEnabled = true
    public var liveMenu: Set<StatusMetric> = [.network]
    public var liveOrder = StatusMetric.menuMetrics
    public var liveOptions: [StatusMetric: StatusMenuOptions] = [:]

    public var island: Set<StatusMetric> = [.cpu, .memory]
    public var islandEnabled = false
    public var menuIconVisible = true

    private enum CodingKeys: String, CodingKey {
        case menu, panelOrder, calendarVisible, processLimit, processSorting, memoryShowsSwap
        case liveMenuEnabled, liveMenu, liveOrder, liveOptions
        case island, islandEnabled, menuIconVisible
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let storedMenu = try values.decodeIfPresent(Set<StatusMetric>.self, forKey: .menu) {
            menu = storedMenu
            if !values.contains(.panelOrder) { menu.formUnion([.gpu, .network, .processes]) }
        }
        panelOrder = try values.decodeIfPresent([StatusMetric].self, forKey: .panelOrder) ?? panelOrder
        calendarVisible = try values.decodeIfPresent(Bool.self, forKey: .calendarVisible) ?? calendarVisible
        processLimit = min(10, max(1, try values.decodeIfPresent(Int.self, forKey: .processLimit) ?? processLimit))
        processSorting = try values.decodeIfPresent(ProcessSorting.self, forKey: .processSorting) ?? processSorting
        memoryShowsSwap = try values.decodeIfPresent(Bool.self, forKey: .memoryShowsSwap) ?? memoryShowsSwap
        liveMenuEnabled = try values.decodeIfPresent(Bool.self, forKey: .liveMenuEnabled) ?? liveMenuEnabled
        liveMenu = try values.decodeIfPresent(Set<StatusMetric>.self, forKey: .liveMenu) ?? liveMenu
        liveOrder = try values.decodeIfPresent([StatusMetric].self, forKey: .liveOrder) ?? liveOrder
        liveOptions = try values.decodeIfPresent([StatusMetric: StatusMenuOptions].self, forKey: .liveOptions) ?? liveOptions
        island = try values.decodeIfPresent(Set<StatusMetric>.self, forKey: .island) ?? island
        islandEnabled = try values.decodeIfPresent(Bool.self, forKey: .islandEnabled) ?? islandEnabled
        menuIconVisible = try values.decodeIfPresent(Bool.self, forKey: .menuIconVisible) ?? menuIconVisible
    }

    public var dashboardOrder: [StatusMetric] { Self.order(panelOrder, allowed: StatusMetric.allCases) }
    public var menuBarOrder: [StatusMetric] { Self.order(liveOrder, allowed: StatusMetric.menuMetrics) }
    public var dashboardMetrics: [StatusMetric] { dashboardOrder.filter(menu.contains) }
    public var menuBarMetrics: [StatusMetric] { menuBarOrder.filter(liveMenu.contains) }

    public func options(for metric: StatusMetric) -> StatusMenuOptions {
        var options = liveOptions[metric] ?? StatusMenuOptions(metric: metric)
        options.fields.formIntersection(metric.menuFields)
        if options.fields.isEmpty { options.fields = StatusMenuOptions(metric: metric).fields }
        return options
    }

    public mutating func resetMenuBar() {
        let defaults = Self()
        liveMenuEnabled = defaults.liveMenuEnabled
        liveMenu = defaults.liveMenu
        liveOrder = defaults.liveOrder
        liveOptions = defaults.liveOptions
    }

    private static func order(_ stored: [StatusMetric], allowed: [StatusMetric]) -> [StatusMetric] {
        var seen: Set<StatusMetric> = []
        return (stored + allowed).filter { allowed.contains($0) && seen.insert($0).inserted }
    }
}
