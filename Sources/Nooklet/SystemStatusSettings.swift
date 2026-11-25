import AppKit
import NookletCore
import SwiftUI

@MainActor
private final class StatusSettingsNavigation: ObservableObject {
    enum Surface: String {
        case dashboard, menuBar
    }

    @Published var surface = Surface.dashboard
}

@MainActor
final class SystemStatusPanel: ToolPanel {
    private let model: ToolboxModel
    private let sampler: StatusSampler
    private let navigation = StatusSettingsNavigation()
    var onPreview: ((NSView) -> Void)?
    var onLivePreviewVisibility: ((Bool) -> Void)?

    init(model: ToolboxModel, sampler: StatusSampler) {
        self.model = model
        self.sampler = sampler
        super.init(heading: L10n.text("系统状态"), detail: L10n.text("设置菜单栏弹窗中的组件，以及单独显示在菜单栏的实时指标。"))
    }

    required init?(coder: NSCoder) { nil }

    override func makeBody() -> NSView {
        NSHostingView(rootView: SystemStatusSettings(model: model, sampler: sampler, navigation: navigation) { [weak self] in
            guard let self else { return }
            onPreview?(view)
        })
    }

    func showDashboardSettings() { navigation.surface = .dashboard }

    override func setVisible(_ visible: Bool) { onLivePreviewVisibility?(visible) }
}

@MainActor
private struct SystemStatusSettings: View {
    private typealias Surface = StatusSettingsNavigation.Surface
    @ObservedObject var model: ToolboxModel
    @ObservedObject var sampler: StatusSampler
    @ObservedObject var navigation: StatusSettingsNavigation
    var openDashboard: () -> Void
    @State private var dragID = UUID().uuidString

    private var preferences: DisplayPreferences { model.preferences }
    private var surface: Surface { navigation.surface }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker(L10n.text("显示位置"), selection: $navigation.surface) {
                    Text(L10n.text("组件面板")).tag(Surface.dashboard)
                    Text(L10n.text("菜单栏指标")).tag(Surface.menuBar)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230, alignment: .leading)
                Spacer()
                if surface == .dashboard {
                    Button(L10n.text("预览组件面板"), systemImage: "arrow.up.right.square", action: openDashboard)
                }
            }
            ScrollView {
                if surface == .dashboard { dashboardSettings } else { menuBarSettings }
            }
            .scrollIndicators(.hidden)
            .id(surface)
        }
    }

    private var dashboardSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: binding(\.calendarVisible)) {
                Text(L10n.text("月历与近期日程")).frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .padding(12)
            .toolboxCard()
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.text("显示组件"))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 13).padding(.vertical, 11)
                Divider()
                metricRows(preferences.dashboardOrder, surface: .dashboard)
            }
            .toolboxCard()
        }
    }

    private var menuBarSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 11) {
                Toggle(L10n.text("显示独立指标图标"), isOn: binding(\.liveMenuEnabled)).toggleStyle(.switch)
                HStack(spacing: 8) {
                    Text(L10n.text("实时预览")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Menu(L10n.text("统一样式")) {
                        ForEach(StatusStyle.allCases, id: \.self) { style in
                            Button(style.title) { applyStyle(style) }
                        }
                    }
                    Button(L10n.text("重置"), systemImage: "arrow.counterclockwise") {
                        model.updateDisplay { $0.resetMenuBar() }
                    }
                    .help(L10n.text("重置菜单栏指标"))
                }
                .controlSize(.small)
                preview
            }
            .padding(13)
            Divider().padding(.horizontal, 13)
            metricRows(preferences.menuBarOrder, surface: .menuBar)
        }
        .toolboxCard()
    }

    private var preview: some View {
        let items = LiveStatusMetric.items(preferences: preferences, readings: sampler.snapshot.readings)
        return ScrollView(.horizontal) {
            Group {
                if items.isEmpty {
                    Text(L10n.text("选择下方的指标。")).font(.caption).foregroundStyle(.secondary)
                } else {
                    LiveStatusStrip(items: items)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(items.map(\.accessibilityText).joined(separator: "，"))
                }
            }
            .frame(minHeight: 34)
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.30), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary) }
    }

    private func metricRows(_ order: [StatusMetric], surface: Surface) -> some View {
        ForEach(Array(order.enumerated()), id: \.element) { index, metric in
            if index > 0 { Divider().padding(.leading, 14) }
            let isMenuBar = surface == .menuBar
            let data = isMenuBar ? preferences.options(for: metric) : nil
            MetricSettingRow(
                metric: metric,
                detail: data.map { options in
                    (metric.menuFields.filter(options.fields.contains).map(\.title)
                        + [options.style.title, options.arrangement.title]).joined(separator: " · ")
                } ?? dashboardDetail(metric),
                isShown: (isMenuBar ? preferences.liveMenu : preferences.menu).contains(metric),
                canExpand: isMenuBar || metric == .memory || metric == .processes,
                canMoveUp: index > 0,
                canMoveDown: index < order.count - 1,
                dragPrefix: "\(dragID)/\(surface.rawValue)/",
                onToggle: { toggle(metric, surface: surface) },
                onMove: { moved, to in move(moved, to: to, surface: surface) },
                previous: index > 0 ? order[index - 1] : nil,
                next: index < order.count - 1 ? order[index + 1] : nil
            ) {
                if isMenuBar {
                    menuOptions(metric)
                } else if metric == .memory {
                    Toggle(L10n.text("显示交换空间"), isOn: binding(\.memoryShowsSwap))
                } else if metric == .processes {
                    Picker(L10n.text("排序"), selection: binding(\.processSorting)) {
                        Text("CPU").tag(ProcessSorting.cpu)
                        Text(L10n.text("内存")).tag(ProcessSorting.memory)
                    }
                    Stepper(L10n.text("最多 %@ 项", preferences.processLimit), value: binding(\.processLimit), in: 1...10)
                }
            }
        }
    }

    private func menuOptions(_ metric: StatusMetric) -> some View {
        let options = preferences.options(for: metric)
        return VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.text("样式"), selection: optionBinding(\.style, metric: metric)) {
                ForEach(StatusStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if metric.menuFields.count > 1 {
                Picker(L10n.text("排列"), selection: optionBinding(\.arrangement, metric: metric)) {
                    ForEach(StatusArrangement.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                HStack(spacing: 10) {
                    ForEach(metric.menuFields, id: \.self) { field in
                        Toggle(field.title, isOn: Binding(
                            get: { model.preferences.options(for: metric).fields.contains(field) },
                            set: { enabled in
                                model.updateDisplay { prefs in
                                    var updated = prefs.options(for: metric)
                                    if enabled { updated.fields.insert(field) }
                                    else if updated.fields.count > 1 { updated.fields.remove(field) }
                                    prefs.liveOptions[metric] = updated
                                }
                            }
                        ))
                        .disabled(options.fields == [field])
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private func dashboardDetail(_ metric: StatusMetric) -> String {
        switch metric {
        case .cpu, .gpu: L10n.text("使用率")
        case .network: L10n.text("上传与下载速率")
        case .disk: L10n.text("可用空间与读写速率")
        case .memory: preferences.memoryShowsSwap ? L10n.text("使用率、已用与交换空间") : L10n.text("使用率与已用")
        case .battery: L10n.text("电量与功率")
        case .processes: L10n.text("最多 %@ 项 · 按%@排序", preferences.processLimit, preferences.processSorting == .cpu ? " CPU " : L10n.text("内存"))
        case .thermal: L10n.text("macOS 热状态")
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<DisplayPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: path] },
                set: { value in model.updateDisplay { $0[keyPath: path] = value } })
    }

    private func optionBinding<Value>(_ path: WritableKeyPath<StatusMenuOptions, Value>, metric: StatusMetric) -> Binding<Value> {
        Binding(get: { model.preferences.options(for: metric)[keyPath: path] }, set: { value in
            model.updateDisplay { prefs in
                var options = prefs.options(for: metric)
                options[keyPath: path] = value
                prefs.liveOptions[metric] = options
            }
        })
    }

    private func applyStyle(_ style: StatusStyle) {
        model.updateDisplay { prefs in
            for metric in StatusMetric.menuMetrics {
                var options = prefs.options(for: metric)
                options.style = style
                prefs.liveOptions[metric] = options
            }
        }
    }

    private func toggle(_ metric: StatusMetric, surface: Surface) {
        let key = surface == .menuBar ? \DisplayPreferences.liveMenu : \DisplayPreferences.menu
        model.updateDisplay { prefs in
            if prefs[keyPath: key].contains(metric) { prefs[keyPath: key].remove(metric) }
            else { prefs[keyPath: key].insert(metric) }
        }
    }

    private func move(_ metric: StatusMetric, to target: StatusMetric, surface: Surface) {
        var order = surface == .menuBar ? preferences.menuBarOrder : preferences.dashboardOrder
        guard metric != target, let source = order.firstIndex(of: metric), let destination = order.firstIndex(of: target) else { return }
        order.remove(at: source)
        order.insert(metric, at: destination)
        model.updateDisplay { prefs in
            if surface == .menuBar { prefs.liveOrder = order }
            else { prefs.panelOrder = order }
        }
    }
}

private struct MetricSettingRow<Details: View>: View {
    var metric: StatusMetric
    var detail: String
    var isShown: Bool
    var canExpand: Bool
    var canMoveUp: Bool
    var canMoveDown: Bool
    var dragPrefix: String
    var onToggle: () -> Void
    var onMove: (StatusMetric, StatusMetric) -> Void
    var previous: StatusMetric?
    var next: StatusMetric?
    @ViewBuilder var details: () -> Details
    @State private var expanded = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: metric.symbol)
                    .frame(width: 30, height: 30)
                    .foregroundStyle(Color(nsColor: metric.color))
                    .background(Color(nsColor: metric.color).opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title).font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: ToolboxAppearance.secondary))
                        .lineLimit(1)
                }
                Spacer()
                if canExpand {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(expanded ? L10n.text("收起%@设置", metric.title) : L10n.text("展开%@设置", metric.title))
                }
                Button(action: onToggle) {
                    Image(systemName: isShown ? "eye" : "eye.slash")
                        .foregroundStyle(isShown ? Color.accentColor : .secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isShown ? L10n.text("隐藏%@", metric.title) : L10n.text("显示%@", metric.title))
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 25, height: 28)
                    .contentShape(Rectangle())
                    .draggable(dragPrefix + metric.rawValue)
                    .accessibilityLabel(L10n.text("调整%@顺序", metric.title))
                    .help(L10n.text("拖动调整顺序"))
                    .contextMenu {
                        Button(L10n.text("上移")) { if let previous { onMove(metric, previous) } }.disabled(!canMoveUp)
                        Button(L10n.text("下移")) { if let next { onMove(metric, next) } }.disabled(!canMoveDown)
                    }
            }.padding(.horizontal, 13).padding(.vertical, 7)
            if expanded {
                VStack(alignment: .leading, spacing: 8, content: details)
                    .padding(.leading, 53)
                    .padding(.trailing, 13)
                    .padding(.bottom, 10)
            }
        }
        .background(targeted ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, item.hasPrefix(dragPrefix),
                  let source = StatusMetric(rawValue: String(item.dropFirst(dragPrefix.count))), source != metric else { return false }
            onMove(source, metric)
            return true
        } isTargeted: { targeted = $0 }
    }
}
