import AppKit
import NookletCore
import SwiftUI

@MainActor
struct StatusDashboard: View {
    static let width: CGFloat = 324
    private static let settingsBarHeight: CGFloat = 38
    private static let tileSpacing: CGFloat = 6
    fileprivate static let tileHeight: CGFloat = 92
    @ObservedObject var model: ToolboxModel
    @ObservedObject var sampler: StatusSampler
    var onSettings: (() -> Void)?

    private var preferences: DisplayPreferences { model.preferences }

    static func preferredHeight(_ preferences: DisplayPreferences, showsSettingsLink: Bool) -> CGFloat {
        let rows = cardRows(preferences.dashboardMetrics)
        let metrics = rows.reduce(CGFloat.zero) { height, row in
            height + (row == [.processes] ? CGFloat(32 + 20 * preferences.processLimit) : tileHeight) + tileSpacing
        }
        let contentHeight = max(90, 15 + metrics + (preferences.calendarVisible ? StatusCalendar.preferredHeight : 0))
        return contentHeight + (showsSettingsLink ? settingsBarHeight + 1 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            dashboardContent
            if let onSettings {
                Rectangle()
                    .fill(Color(nsColor: ToolboxAppearance.rule))
                    .frame(height: 1)
                    .accessibilityHidden(true)
                HStack {
                    Spacer()
                    Button(action: onSettings) {
                        Label(L10n.text("显示设置…"), systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: model.general.tint(ToolboxAppearance.blue, amount: 0.22)))
                    .keyboardShortcut(",", modifiers: .command)
                }
                .padding(.horizontal, 12)
                .frame(height: Self.settingsBarHeight)
            }
        }
        .foregroundStyle(Color(nsColor: ToolboxAppearance.ink))
        .background(Color(nsColor: model.general.tint(ToolboxAppearance.window, amount: 0.045)))
    }

    private var dashboardContent: some View {
        DashboardScrollView {
            VStack(spacing: Self.tileSpacing) {
                if preferences.dashboardMetrics.isEmpty, !preferences.calendarVisible {
                    Text(L10n.text("暂无显示的组件"))
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: ToolboxAppearance.secondary))
                        .frame(maxWidth: .infinity, minHeight: 74)
                }
                ForEach(Self.cardRows(preferences.dashboardMetrics), id: \.self) { row in
                    if row == [.processes] {
                        processCard
                    } else {
                        HStack(spacing: Self.tileSpacing) {
                            ForEach(row, id: \.self) { metric in
                                DashboardMetricCard(metric: metric, reading: sampler.snapshot.readings[metric],
                                                    memoryShowsSwap: preferences.memoryShowsSwap)
                            }
                            if row.count == 1 {
                                Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
                            }
                        }
                    }
                }
                if preferences.calendarVisible { StatusCalendar().padding(.top, 3) }
            }
            .padding(.horizontal, 7)
            .padding(.top, 7)
            .padding(.bottom, 8)
            .foregroundStyle(Color(nsColor: ToolboxAppearance.ink))
        }
    }

    private static func cardRows(_ metrics: [StatusMetric]) -> [[StatusMetric]] {
        var rows: [[StatusMetric]] = []
        for metric in metrics {
            if metric != .processes, let last = rows.last,
               last.count == 1, last[0] != .processes {
                rows[rows.count - 1].append(metric)
            } else {
                rows.append([metric])
            }
        }
        return rows
    }

    private var processCard: some View {
        let processes = sampler.snapshot.processes
        let visible = preferences.processSorting == .cpu ? processes?.byCPU ?? [] : processes?.byMemory ?? []
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 9) {
                Label(L10n.text("进程"), systemImage: "list.bullet").frame(maxWidth: .infinity, alignment: .leading)
                processHeader("CPU", order: .cpu, width: 54)
                    .help(L10n.text("采样间隔内的平均 CPU 占用。首次显示系统报告的近期占用。一个逻辑核心满载为 100%。"))
                processHeader(L10n.text("内存"), order: .memory, width: 60)
                    .help(L10n.text("按显示的内存值排序。带 * 的数值是常驻内存（RSS），其余数值是物理内存占用。"))
            }
            .font(.system(size: 10, weight: .semibold))
            .frame(height: 17)
            ForEach(visible.prefix(preferences.processLimit)) { process in
                HStack(spacing: 9) {
                    processLabel(process)
                    Text(process.cpu.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                        .frame(width: 54, alignment: .trailing)
                    processMemory(process)
                }
                .font(.system(size: 11).monospacedDigit())
                .frame(height: 18)
            }
            if visible.isEmpty {
                Text(processes == nil ? L10n.text("正在读取进程…") : L10n.text("暂无可读取的进程"))
                    .foregroundStyle(Color(nsColor: ToolboxAppearance.secondary)).font(.caption)
                    .frame(height: 18)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: CGFloat(32 + 19 * preferences.processLimit), alignment: .top)
        .toolboxCard()
    }

    private func processMemory(_ process: ProcessReading) -> some View {
        let size = process.memory.map { statusSize($0, style: .memory) } ?? "—"
        let description = if process.memory == nil {
            L10n.text("macOS 未提供该进程的内存数据")
        } else if process.memoryIsResident {
            L10n.text("常驻内存（RSS），物理内存占用不可读")
        } else {
            L10n.text("物理内存占用")
        }
        return Text(size + (process.memoryIsResident ? "*" : ""))
            .frame(width: 60, alignment: .trailing)
            .help(description)
            .accessibilityLabel(process.memory == nil ? description : "\(size)，\(description)")
    }

    private func processLabel(_ process: ProcessReading) -> some View {
        let app = NSRunningApplication(processIdentifier: process.id)
        return HStack(spacing: 7) {
            Group {
                if let icon = app?.icon { Image(nsImage: icon).resizable().scaledToFit() }
                else {
                    Image(systemName: "gearshape.2").font(.system(size: 9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: ToolboxAppearance.raised), in: RoundedRectangle(cornerRadius: 4))
                }
            }.frame(width: 15, height: 15).accessibilityHidden(true)
            Text(app?.localizedName ?? process.name).lineLimit(1)
                .help(app?.localizedName ?? process.name)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func processHeader(_ title: String, order: ProcessSorting, width: CGFloat) -> some View {
        Button {
            model.updateDisplay { $0.processSorting = order }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if preferences.processSorting == order { Image(systemName: "chevron.down").font(.system(size: 6)) }
            }
            .frame(width: width, alignment: .trailing)
        }
        .buttonStyle(ToolIconButton())
        .accessibilityLabel(L10n.text("按%@排序", title))
        .accessibilityAddTraits(preferences.processSorting == order ? .isSelected : [])
    }
}

private struct DashboardScrollView<Content: View>: NSViewRepresentable {
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false

        let document = DocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let host = NSHostingView(rootView: content())
        host.sizingOptions = .intrinsicContentSize
        host.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(host)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            host.topAnchor.constraint(equalTo: document.topAnchor),
            host.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let host = scroll.documentView?.subviews.first as? NSHostingView<Content>
        host?.rootView = content()
    }
}

private struct DashboardMetricCard: View {
    let metric: StatusMetric
    let reading: MetricReading?
    let memoryShowsSwap: Bool

    private var detail: String {
        guard let reading else { return L10n.text("等待读取…") }
        if metric == .memory, !memoryShowsSwap, let used = reading.fields[.memoryUsed] { return L10n.text("已用 %@", used) }
        return reading.detail
    }

    private var value: String { reading?.value ?? "—" }
    private var tint: Color { Color(nsColor: metric.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: metric.symbol).foregroundStyle(tint).accessibilityHidden(true)
                Text(metric.title).fontWeight(.semibold)
                Spacer(minLength: 0)
                if let badge = reading?.badge {
                    Text(badge).font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .padding(.horizontal, 7).frame(height: 17)
                        .background(Color(nsColor: ToolboxAppearance.ink).opacity(0.075), in: Capsule())
                }
            }
            .font(.system(size: 11))
            .frame(height: 17)
            headline
            if metric != .thermal {
                MetricGraph(primary: reading?.history ?? [], secondary: reading?.secondaryHistory ?? [],
                            tint: tint, metric: metric)
                    .frame(height: 22)
                    .accessibilityHidden(true)
            }
            detailLine
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Color(nsColor: ToolboxAppearance.secondary))
                .lineLimit(1).minimumScaleFactor(0.79).help(detail)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: StatusDashboard.tileHeight, alignment: .leading)
        .toolboxCard()
        .accessibilityElement(children: .combine)
    }

    private var headline: some View {
        let parts = value.split(separator: " ", maxSplits: 1)
        let suffix = value.hasSuffix("%") ? "%" : parts.count > 1 ? String(parts[1]) : ""
        let number = value.hasSuffix("%") ? String(value.dropLast()) : parts.first.map(String.init) ?? value
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(number).font(.system(size: 20, weight: .semibold).monospacedDigit())
            if !suffix.isEmpty { Text(suffix).font(.system(size: 10.5, weight: .medium)) }
            if metric == .disk, value != "—" { Text(L10n.text("可用")).font(.system(size: 10.5)) }
        }
        .lineLimit(1).minimumScaleFactor(0.72)
    }

    @ViewBuilder private var detailLine: some View {
        if metric == .disk, let reading {
            HStack(spacing: 7) {
                Label { Text(reading.fields[.read] ?? "—") } icon: {
                    Text(L10n.text("读")).foregroundStyle(tint).fontWeight(.semibold)
                }
                Label { Text(reading.fields[.write] ?? "—") } icon: {
                    Text(L10n.text("写")).foregroundStyle(Color(nsColor: ToolboxAppearance.violet)).fontWeight(.semibold)
                }
            }
            .labelStyle(TransferLabelStyle())
        } else {
            Text(detail)
        }
    }
}

private struct TransferLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

private struct MetricGraph: View {
    let primary: [Double]
    let secondary: [Double]
    let tint: Color
    let metric: StatusMetric

    var body: some View {
        Canvas { context, size in
            if metric == .cpu || metric == .gpu {
                let values = Array(primary.suffix(24))
                let step = size.width / 24
                let width = max(1, step * 0.58)
                let ceiling = max(0.35, values.max() ?? 0)
                for (index, value) in values.enumerated() {
                    let height = max(1, min(1, max(0, value) / ceiling) * size.height)
                    let x = CGFloat(24 - values.count + index) * step
                    let bar = CGRect(x: x, y: size.height - height, width: width, height: height)
                    context.fill(Path(roundedRect: bar, cornerRadius: 1.3), with: .color(tint))
                }
                return
            }
            let autoScale = metric == .network || metric == .disk
            let ceiling = autoScale ? max(1, primary.max() ?? 0, secondary.max() ?? 0) : 1
            draw(primary, color: tint, ceiling: ceiling, size: size, context: context)
            draw(secondary, color: Color(nsColor: ToolboxAppearance.violet), ceiling: ceiling, size: size, context: context)
        }
    }

    private func draw(_ values: [Double], color: Color, ceiling: Double, size: CGSize, context: GraphicsContext) {
        guard let last = values.last else { return }
        let values = values.count == 1 ? [last, last] : values
        var line = Path()
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: 1 + (size.width - 2) * Double(index) / Double(values.count - 1),
                                y: size.height - 1 - max(0, min(1, value / ceiling)) * (size.height - 2))
            if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        var area = line
        area.addLine(to: CGPoint(x: size.width - 1, y: size.height))
        area.addLine(to: CGPoint(x: 1, y: size.height))
        area.closeSubpath()
        context.fill(area, with: .color(color.opacity(0.10)))
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
    }
}
