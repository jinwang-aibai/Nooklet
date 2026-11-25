import AppKit
import NookletCore
import SwiftUI

extension MenuBarVisibility {
    var title: String {
        switch self {
        case .visible: L10n.text("正常显示")
        case .hidden: L10n.text("按需隐藏")
        case .alwaysHidden: L10n.text("始终隐藏")
        }
    }

    var symbol: String {
        switch self {
        case .visible: "menubar.rectangle"
        case .hidden: "eye.slash"
        case .alwaysHidden: "lock"
        }
    }

    var detail: String {
        switch self {
        case .visible: L10n.text("收起时显示")
        case .hidden: L10n.text("单击箭头显示")
        case .alwaysHidden: L10n.text("仅在全部展开时显示")
        }
    }
}

@MainActor
final class MenuBarPanel: ToolPanel {
    private let model: ToolboxModel
    private let manager: MenuBarController
    private let presentation = MenuBarManagementPresentation()

    init(model: ToolboxModel) {
        self.model = model
        self.manager = model.menuBar
        super.init(heading: L10n.text("菜单栏管理"), detail: L10n.text("决定应用图标何时出现在菜单栏。"))
    }

    required init?(coder: NSCoder) { nil }

    override func makeBody() -> NSView {
        manager.onChange = { [weak self] in self?.render() }
        render()
        let hosting = NSHostingView(rootView: MenuBarManagementView(presentation: presentation) { [weak self] action in
            self?.perform(action)
        })
        hosting.sizingOptions = []
        return hosting
    }

    override func setVisible(_ visible: Bool) { manager.setWatching(visible) }
    override func endUse() {
        manager.onChange = nil
        manager.setWatching(false)
    }

    func render() {
        let access: MenuBarManagementPresentation.Access
        if !manager.supported {
            access = .unavailable(L10n.text("当前 macOS 不支持菜单栏收起。"))
        } else if !manager.canHide {
            access = .unavailable(L10n.text("将 Nooklet 拖到「应用程序」后，从那里打开即可管理菜单栏。"))
        } else {
            access = manager.trusted ? .ready : .needsPermission
        }
        presentation.snapshot = .init(
            access: access, enabled: manager.enabled, scanning: manager.scanning,
            applying: manager.applyingRules, canVerify: manager.canVerifyRules,
            menuIconVisible: model.preferences.menuIconVisible, issue: manager.message,
            items: manager.editableApps.map { .init(app: $0, rule: manager.rule($0)) }
        )
    }

    private func perform(_ action: MenuBarManagementView.Action) {
        switch action {
        case .enable(let enabled): manager.setEnabled(enabled)
        case .move(let id, let rule): manager.setRule(rule, for: id)
        case .verify(let mode): manager.verifyRules(mode)
        case .refresh: manager.refresh(retry: true)
        case .grant: manager.requestAccessibility()
        case .showMenuIcon(let visible):
            model.updateDisplay { $0.menuIconVisible = visible }
        }
    }
}

@MainActor
final class MenuBarManagementPresentation: ObservableObject {
    enum Access: Equatable {
        case ready
        case needsPermission
        case unavailable(String)
    }

    struct Item: Identifiable {
        let app: MenuBarApp
        let rule: MenuBarVisibility
        var id: String { app.id }
    }

    struct Snapshot {
        var access: Access = .unavailable("")
        var enabled = false
        var scanning = false
        var applying = false
        var canVerify = false
        var menuIconVisible = true
        var issue: String?
        var items: [Item] = []
    }

    @Published var snapshot = Snapshot()
}

@MainActor
struct MenuBarManagementView: View {
    enum Action {
        case enable(Bool)
        case move(String, MenuBarVisibility)
        case verify(MenuBarExpansion)
        case refresh
        case grant
        case showMenuIcon(Bool)
    }

    private struct Drag {
        let id: String
        let source: MenuBarVisibility
        let location: CGPoint
    }

    private struct GroupFrames: PreferenceKey {
        static let defaultValue: [MenuBarVisibility: CGRect] = [:]

        static func reduce(value: inout [MenuBarVisibility: CGRect], nextValue: () -> [MenuBarVisibility: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    @ObservedObject var presentation: MenuBarManagementPresentation
    var send: (Action) -> Void
    @State private var selectedID: String?
    @State private var actionID: String?
    @State private var showsRulePreview = false
    @State private var previewMode = MenuBarExpansion.collapsed
    @State private var groupFrames: [MenuBarVisibility: CGRect] = [:]
    @GestureState private var drag: Drag?
    private let boardSpace = "menuBarManagementBoard"

    private var state: MenuBarManagementPresentation.Snapshot { presentation.snapshot }
    private var secondary: Color { Color(nsColor: ToolboxAppearance.secondary) }
    private var accent: Color { Color(nsColor: ToolboxAppearance.blue) }
    private var dropGroup: MenuBarVisibility? {
        drag.flatMap { destination(at: $0.location, from: $0.source) }
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                managementContent.frame(minHeight: viewport.size.height, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
        }
        .coordinateSpace(name: boardSpace)
        .onPreferenceChange(GroupFrames.self) { groupFrames = $0 }
        .overlay(alignment: .topLeading) {
            if let drag, let moving = state.items.first(where: { $0.id == drag.id }) {
                appIcon(moving.app, size: 23)
                    .padding(6)
                    .toolboxCard(radius: 7)
                    .position(x: drag.location.x + 17, y: drag.location.y - 17)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Color(nsColor: ToolboxAppearance.ink))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: state.items.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
            if let actionID, !ids.contains(actionID) { self.actionID = nil }
        }
    }

    private var managementContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.access == .ready { controls }
            if let issue = state.issue {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch state.access {
            case .ready:
                rules
            case .needsPermission:
                accessCard(L10n.text("允许读取菜单栏图标"),
                           detail: L10n.text("在「隐私与安全性 → 辅助功能」里开启 Nooklet，然后返回此页。")) {
                    Button(L10n.text("打开辅助功能设置")) { send(.grant) }
                        .buttonStyle(.borderedProminent)
                }
            case .unavailable(let reason):
                accessCard(L10n.text("菜单栏管理不可用"), detail: reason) { EmptyView() }
            }
            Toggle(L10n.text("显示 Nooklet 主图标"), isOn: Binding(get: { state.menuIconVisible }, set: { send(.showMenuIcon($0)) }))
                .toggleStyle(.checkbox)
        }
        .padding(.vertical, 2)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("收起菜单栏图标")).font(.subheadline.weight(.semibold))
                Text(managementStatus).font(.caption).foregroundStyle(secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button(L10n.text("预览规则")) { showsRulePreview.toggle() }
                .popover(isPresented: $showsRulePreview, arrowEdge: .bottom) {
                    preview
                }
            Button { send(.refresh) } label: {
                Label(L10n.text("刷新应用列表"), systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }
            .help(L10n.text("刷新应用列表"))
            Toggle(L10n.text("收起菜单栏图标"), isOn: Binding(get: { state.enabled }, set: {
                previewMode = .collapsed
                send(.enable($0))
            }))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(12)
        .toolboxCard()
    }

    private var managementStatus: String {
        if !state.enabled { return L10n.text("关闭时可以调整分组，开启后应用规则。") }
        if state.applying { return L10n.text("正在将规则应用到菜单栏…") }
        if state.issue != nil { return L10n.text("请查看下方提示。") }
        return L10n.text("规则自动保存，开启时会应用到菜单栏。")
    }

    private var preview: some View {
        let visible = state.items.filter { previewMode.shows($0.rule) }
        return VStack(alignment: .leading, spacing: 9) {
            Picker(L10n.text("预览时显示"), selection: $previewMode) {
                Text(L10n.text("收起")).tag(MenuBarExpansion.collapsed)
                Text(L10n.text("按需展开")).tag(MenuBarExpansion.hidden)
                Text(L10n.text("全部展开")).tag(MenuBarExpansion.all)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            HStack(spacing: 9) {
                Image(systemName: previewMode == .collapsed ? "chevron.left" : "chevron.down")
                    .foregroundStyle(secondary)
                    .accessibilityHidden(true)
                if visible.isEmpty {
                    Text(state.scanning && state.items.isEmpty ? L10n.text("正在读取菜单栏…") : L10n.text("此状态下没有受管理的应用"))
                        .font(.caption).foregroundStyle(secondary)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(visible) { item in
                                appIcon(item.app, size: 20)
                                    .help(item.app.name)
                                    .accessibilityLabel(item.app.name)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .accessibilityLabel(L10n.text("该状态下显示的应用"))
                }
            }
            .frame(height: 28)
            .padding(.horizontal, 9)
            .background(Color(nsColor: ToolboxAppearance.raised), in: RoundedRectangle(cornerRadius: 7))
            Text(L10n.text("实际排列由 macOS 决定。"))
                .font(.caption).foregroundStyle(secondary)
            Button(L10n.text("在菜单栏验证")) {
                showsRulePreview = false
                send(.verify(previewMode))
            }
            .disabled(!state.canVerify || state.items.isEmpty)
            .help(state.enabled ? L10n.text("在实际菜单栏应用所选状态。") : L10n.text("开启收起功能后可以在菜单栏验证。"))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .frame(width: 310)
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.items.isEmpty && !state.scanning
                 ? L10n.text("开启应用自己的菜单栏图标后，刷新列表。")
                 : L10n.text("拖动或点按应用图标可更改分组。"))
                .font(.caption).foregroundStyle(secondary)
            ForEach(MenuBarVisibility.allCases, id: \.self) { group in
                groupCard(group, items: state.items.filter { $0.rule == group })
            }
        }
    }

    private func groupCard(_ group: MenuBarVisibility, items: [MenuBarManagementPresentation.Item]) -> some View {
        let targeted = dropGroup == group
        let shape = RoundedRectangle(cornerRadius: 10)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Label(group.title, systemImage: group.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(targeted ? accent : Color(nsColor: ToolboxAppearance.ink))
                    Text("\(items.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(secondary)
                        .accessibilityLabel(L10n.text("%@ 个应用", items.count))
                }
                Text(group.detail).font(.caption).foregroundStyle(secondary)
            }
            .frame(width: 115, alignment: .leading)
            Divider().frame(height: 28).accessibilityHidden(true)
            if items.isEmpty {
                Text(L10n.text("暂无应用"))
                    .font(.caption)
                    .foregroundStyle(secondary)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 6)], spacing: 6) {
                    ForEach(items) { item in appTile(item) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(targeted ? Color(nsColor: ToolboxAppearance.selection) : Color(nsColor: ToolboxAppearance.card), in: shape)
        .overlay { shape.strokeBorder(targeted ? accent : Color(nsColor: ToolboxAppearance.rule)).allowsHitTesting(false) }
        .background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(boardSpace))
                let viewport = proxy.bounds(of: .named(boardSpace))?
                    .offsetBy(dx: frame.minX, dy: frame.minY) ?? .zero
                Color.clear.preference(key: GroupFrames.self, value: [group: frame.intersection(viewport)])
            }
        }
    }

    private func destination(at point: CGPoint, from source: MenuBarVisibility) -> MenuBarVisibility? {
        MenuBarVisibility.allCases.first { $0 != source && groupFrames[$0]?.contains(point) == true }
    }

    private func appTile(_ item: MenuBarManagementPresentation.Item) -> some View {
        let isSelected = selectedID == item.id
        let shape = RoundedRectangle(cornerRadius: 7)
        return Button {
            selectedID = item.id
            actionID = item.id
        } label: {
            VStack(spacing: 4) {
                appIcon(item.app, size: 20).accessibilityHidden(true)
                Text(item.app.name).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 3)
            .background(Color(nsColor: isSelected ? ToolboxAppearance.selection : ToolboxAppearance.raised), in: shape)
            .overlay {
                shape.strokeBorder(isSelected ? accent : Color.clear).allowsHitTesting(false)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.app.name)
        .accessibilityValue(item.rule.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(item.app.extras.count > 1 ? L10n.text("%@ · %@ 个图标一起分组", item.app.name, item.app.extras.count) : item.app.name)
        .popover(isPresented: Binding(get: { actionID == item.id }, set: { presented in
            if !presented && actionID == item.id { actionID = nil }
        }), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.app.name).font(.subheadline.weight(.semibold))
                Text(L10n.text("当前分组：%@", item.rule.title)).font(.caption).foregroundStyle(secondary)
                HStack(spacing: 6) {
                    ForEach(MenuBarVisibility.allCases, id: \.self) { group in
                        Button(group.title) {
                            actionID = nil
                            send(.move(item.id, group))
                        }
                        .disabled(group == item.rule)
                        .accessibilityLabel(L10n.text("将%@移到%@", item.app.name, group.title))
                    }
                }
            }
            .padding(12)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named(boardSpace))
                .updating($drag) { value, current, _ in
                    current = Drag(id: item.id, source: item.rule, location: value.location)
                }
                .onEnded { value in
                    guard let group = destination(at: value.location, from: item.rule) else { return }
                    selectedID = item.id
                    send(.move(item.id, group))
                }
        )
        .contextMenu {
            ForEach(MenuBarVisibility.allCases.filter { $0 != item.rule }, id: \.self) { group in
                Button(L10n.text("移到%@", group.title)) {
                    selectedID = item.id
                    send(.move(item.id, group))
                }
            }
        }
    }

    private func accessCard<Actions: View>(_ title: String, detail: String,
                                           @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(secondary)
            actions()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolboxCard()
    }

    @ViewBuilder
    private func appIcon(_ app: MenuBarApp, size: CGFloat) -> some View {
        Group {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(Color(nsColor: ToolboxAppearance.ink))
    }
}
