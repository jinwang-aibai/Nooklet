import AppKit
import NookletCore
import SwiftUI

extension StatusStyle {
    var title: String {
        switch self {
        case .detailed: L10n.text("详细")
        case .compact: L10n.text("紧凑")
        case .minimal: L10n.text("极简")
        }
    }
}

extension StatusArrangement {
    var title: String {
        switch self {
        case .automatic: L10n.text("自动")
        case .horizontal: L10n.text("横向排列")
        case .vertical: L10n.text("上下排列")
        }
    }
}

extension StatusField {
    var title: String {
        switch self {
        case .usage: L10n.text("使用率")
        case .upload: L10n.text("上传速率")
        case .download: L10n.text("下载速率")
        case .freeSpace: L10n.text("可用空间")
        case .read: L10n.text("读取速率")
        case .write: L10n.text("写入速率")
        case .memoryUsed: L10n.text("已用内存")
        case .swap: L10n.text("交换空间")
        case .batteryLevel: L10n.text("电量")
        case .batteryPower: L10n.text("功率")
        case .powerSource: L10n.text("电源状态")
        case .thermalState: L10n.text("热状态")
        }
    }

    func text(_ value: String, style: StatusStyle) -> String {
        switch self {
        case .usage: return style == .detailed ? L10n.text("使用率 %@", value) : value
        case .batteryLevel: return style == .detailed ? L10n.text("电量 %@", value) : value
        case .powerSource, .thermalState: return value
        case .upload: return style == .detailed ? L10n.text("上传 %@", value) : "↑\(value)"
        case .download: return style == .detailed ? L10n.text("下载 %@", value) : "↓\(value)"
        case .read: return style == .detailed ? L10n.text("读 %@", value) : "R \(value)"
        case .write: return style == .detailed ? L10n.text("写 %@", value) : "W \(value)"
        case .freeSpace: return style == .detailed ? L10n.text("可用 %@", value) : value
        case .memoryUsed: return style == .detailed ? L10n.text("已用 %@", value) : value
        case .swap: return style == .detailed ? L10n.text("交换 %@", value) : "↔ \(value)"
        case .batteryPower: return value
        }
    }
}

struct LiveStatusMetric: Identifiable, Equatable {
    struct Field: Identifiable, Equatable {
        let id: StatusField
        let value: String
    }

    let id: StatusMetric
    let style: StatusStyle
    let vertical: Bool
    let fields: [Field]

    var accessibilityText: String {
        ([id.title] + fields.map { "\($0.id.title) \($0.value)" }).joined(separator: "，")
    }

    static func items(preferences: DisplayPreferences, readings: [StatusMetric: MetricReading]) -> [Self] {
        preferences.menuBarMetrics.map { metric in
            let options = preferences.options(for: metric)
            let fields = metric.menuFields.filter(options.fields.contains)
            let vertical = options.arrangement == .vertical
                || (options.arrangement == .automatic && (metric == .network || metric == .disk))
            return Self(id: metric, style: options.style, vertical: vertical && fields.count > 1,
                        fields: fields.map { Field(id: $0, value: readings[metric]?.fields[$0] ?? "—") })
        }
    }
}

struct LiveStatusStrip: View {
    let items: [LiveStatusMetric]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items) { item in
                HStack(spacing: 4) {
                    if item.style != .minimal {
                        Image(systemName: item.id.symbol).font(.system(size: 11, weight: .medium))
                    }
                    if item.vertical {
                        VStack(alignment: .leading, spacing: 0) {
                            fieldLine(Array(item.fields.prefix(1)), style: item.style, fontSize: 8.5)
                            fieldLine(Array(item.fields.dropFirst()), style: item.style, fontSize: 8.5)
                        }
                    } else {
                        fieldLine(item.fields, style: item.style, fontSize: 11)
                    }
                }
            }
        }
        .fixedSize()
    }

    private func fieldLine(_ fields: [LiveStatusMetric.Field], style: StatusStyle, fontSize: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(fields) { field in
                Text(field.id.text(field.value, style: style))
                    .font(.system(size: fontSize, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: rateWidth(for: field.id, style: style, fontSize: fontSize), alignment: .leading)
            }
        }
    }

    private func rateWidth(for field: StatusField, style: StatusStyle, fontSize: CGFloat) -> CGFloat? {
        // Keep neighboring menu bar items in place when the rate changes units.
        switch field {
        case .upload, .download:
            return ceil(fontSize * (style == .detailed ? 7.1 : 5.2))
        case .read, .write:
            return ceil(fontSize * (style == .detailed ? 7.9 : 6.3))
        default:
            return nil
        }
    }
}

@MainActor
final class LiveStatusItem {
    private var item: NSStatusItem?
    private var rendered: [LiveStatusMetric] = []
    private var onClick: ((NSStatusBarButton) -> Void)?

    func configure(enabled: Bool, onClick: @escaping (NSStatusBarButton) -> Void) {
        if enabled == (item != nil) { return }
        if !enabled {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            rendered = []
            self.onClick = nil
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Nooklet.SystemStatus.Live"
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        self.item = item
        self.onClick = onClick
    }

    func render(_ items: [LiveStatusMetric]) {
        guard let item, let button = item.button, items != rendered else { return }
        let renderer = ImageRenderer(content: LiveStatusStrip(items: items).foregroundStyle(.black))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return }
        image.isTemplate = true
        item.length = ceil(image.size.width) + 4
        button.image = image
        button.setAccessibilityLabel(L10n.text("Nooklet 实时指标，") + items.map(\.accessibilityText).joined(separator: "，"))
        button.toolTip = items.map(\.accessibilityText).joined(separator: "\n")
        rendered = items
    }

    @objc private func clicked(_ button: NSStatusBarButton) { onClick?(button) }
}
