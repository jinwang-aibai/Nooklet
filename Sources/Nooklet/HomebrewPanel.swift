import AppKit
import SwiftUI

@MainActor
final class HomebrewPanel: ToolPanel {
    private let model: HomebrewModel

    init(heading: String, detail: String, model: HomebrewModel) {
        self.model = model
        super.init(heading: heading, detail: detail)
    }

    required init?(coder: NSCoder) { nil }

    override func makeBody() -> NSView {
        let hosting = NSHostingView(rootView: HomebrewView(model: model))
        hosting.sizingOptions = []
        return hosting
    }

    override func setVisible(_ visible: Bool) {
        if visible { model.startIfNeeded() }
    }
}

@MainActor
private struct HomebrewView: View {
    private enum Section: String, CaseIterable {
        case installed = "已安装", search = "搜索", taps = "软件源", diagnostics = "诊断"

        var symbol: String {
            switch self {
            case .installed: "shippingbox.fill"
            case .search: "magnifyingglass"
            case .taps: "point.3.connected.trianglepath.dotted"
            case .diagnostics: "stethoscope"
            }
        }
    }

    private enum Filter: String, CaseIterable {
        case all = "全部", formula = "Formula", cask = "Cask", outdated = "可升级"
    }

    private enum Removal {
        case package(BrewPackage), tap(String)

        var name: String {
            switch self {
            case .package(let package): package.name
            case .tap(let name): name
            }
        }
        var action: String {
            switch self {
            case .package: L10n.text("卸载")
            case .tap: L10n.text("移除")
            }
        }
    }

    @ObservedObject var model: HomebrewModel
    @State private var section: Section = .installed
    @State private var filter: Filter = .all
    @State private var installedQuery = ""
    @State private var searchQuery = ""
    @State private var selectedInstalled: String?
    @State private var selectedResult: String?
    @State private var tapName = ""
    @State private var removal: Removal?
    @State private var pathDraft = ""
    @State private var confirmation: BrewMaintenance?
    @State private var consoleExpanded = false

    private var filtered: [BrewPackage] {
        let needle = installedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.installed.filter { package in
            guard needle.isEmpty || package.name.localizedStandardContains(needle)
                || package.description?.localizedStandardContains(needle) == true else { return false }
            switch filter {
            case .all: return true
            case .formula: return package.kind == .formula
            case .cask: return package.kind == .cask
            case .outdated: return package.outdated
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusBand
            navigation
            if model.executable != nil || section == .diagnostics {
                switch section {
                case .installed: installedView
                case .search: searchView
                case .taps: tapsView
                case .diagnostics: diagnosticsView
                }
            } else if model.busy {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在查找 Homebrew…")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(L10n.text("未找到 Homebrew"), systemImage: "shippingbox")
                } actions: {
                    Button(L10n.text("设置 brew 路径"), systemImage: "terminal") { section = .diagnostics }
                        .buttonStyle(WorkspaceActionStyle(tint: .accent, prominent: true))
                    Link(L10n.text("打开 Homebrew 官网"), destination: URL(string: "https://brew.sh/")!)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            console
        }
        .onAppear { pathDraft = model.configuredPath }
        .onChange(of: model.configuredPath) { _, path in pathDraft = path }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { operation in
            Button(operation.title, role: operation == .cleanup ? .destructive : nil) { model.perform(operation) }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: { operation in
            Text(operation == .cleanup ? L10n.text("移除 Homebrew 的旧版本、过期下载和缓存。") : L10n.text("升级 Homebrew 当前可升级的软件包。"))
        }
        .alert(removal.map { "\($0.action)「\($0.name)」？" } ?? "", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), presenting: removal) { item in
            Button(item.action, role: .destructive) {
                switch item {
                case .package(let package): model.change(.uninstall, package: package)
                case .tap(let name): model.changeTap(name, adding: false)
                }
            }
            Button(L10n.text("取消"), role: .cancel) {}
        }
    }

    private var statusBand: some View {
        HStack(spacing: 15) {
            counter(L10n.text("已安装"), value: model.installed.count, symbol: "shippingbox.fill", tint: .neutral)
            counter(L10n.text("可升级"), value: model.installed.filter(\.outdated).count, symbol: "arrow.up.circle.fill", tint: .accent)
            Divider().frame(height: 27)
            Label(model.executable?.path ?? L10n.text("尚未检测到 brew"), systemImage: "terminal")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(nsColor: ToolboxAppearance.secondary))
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(model.executable?.path ?? L10n.text("可在诊断页设置路径"))
            Button(L10n.text("刷新"), systemImage: "arrow.clockwise", action: model.refresh)
                .buttonStyle(WorkspaceActionStyle(tint: .accent))
                .disabled(model.busy)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background {
            LinearGradient(colors: [WorkspaceTint.accent.foreground.opacity(0.07), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .clipShape(RoundedRectangle(cornerRadius: 11))
        }
        .toolboxCard()
    }

    private func counter(_ title: String, value: Int, symbol: String, tint: WorkspaceTint) -> some View {
        HStack(spacing: 7) {
            WorkspaceGlyph(symbol: symbol, tint: tint, size: 29)
            VStack(alignment: .leading, spacing: 1) {
                Text(value, format: .number).font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint.foreground)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .fixedSize()
    }

    private var navigation: some View {
        HStack(spacing: 4) {
            ForEach(Section.allCases, id: \.self) { item in
                Button {
                    section = item
                } label: {
                    Label(L10n.text(item.rawValue), systemImage: item.symbol)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(WorkspaceActionStyle(tint: section == item ? .accent : .neutral, prominent: section == item))
                .accessibilityAddTraits(section == item ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Color(nsColor: ToolboxAppearance.raised), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Homebrew 页面"))
    }

    private var installedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WorkspaceField(title: L10n.text("筛选已安装的包"), symbol: "magnifyingglass", text: $installedQuery, tint: .accent)
                Picker(L10n.text("包类型"), selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                }.labelsHidden().tint(WorkspaceTint.accent.foreground).fixedSize()
            }
            packageBrowser(filtered, selection: $selectedInstalled, empty: model.busy ? L10n.text("正在读取…") : L10n.text("没有匹配的包"))
        }
    }

    private var searchView: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                WorkspaceField(title: L10n.text("搜索 Formula 或 Cask"), symbol: "magnifyingglass", text: $searchQuery)
                    .onSubmit { search(query) }
                Button(L10n.text("搜索"), systemImage: "magnifyingglass") { search(query) }
                    .buttonStyle(WorkspaceActionStyle(tint: .accent, prominent: true))
                    .disabled(!BrewPackage.validName(query) || model.busy)
            }
            packageBrowser(model.results, selection: $selectedResult,
                           empty: model.busy ? L10n.text("正在读取…") : L10n.text("没有搜索结果"), fetchDetails: true)
        }
    }

    private func search(_ query: String) {
        guard !model.busy, BrewPackage.validName(query) else { return }
        selectedResult = nil
        model.search(query, kinds: BrewPackageKind.allCases)
    }

    private func packageBrowser(_ packages: [BrewPackage], selection: Binding<String?>, empty: String,
                                fetchDetails: Bool = false) -> some View {
        HStack(spacing: 10) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if packages.isEmpty {
                        Text(empty).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 70)
                    }
                    ForEach(packages) { package in
                        let selected = selection.wrappedValue == package.id
                        Button {
                            selection.wrappedValue = package.id
                            if fetchDetails, !model.busy, package.availableVersion == nil { model.showDetails(package) }
                        } label: {
                            HStack(spacing: 7) {
                                WorkspaceGlyph(symbol: package.kind == .formula ? "shippingbox.fill" : "macwindow",
                                               tint: selected ? .accent : .neutral, size: 27)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(package.name).lineLimit(1).truncationMode(.middle)
                                    Text(package.kind.title).font(.caption)
                                        .foregroundStyle(WorkspaceTint.neutral.foreground)
                                }
                                Spacer(minLength: 0)
                                if package.outdated {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .foregroundStyle(WorkspaceTint.accent.foreground)
                                        .accessibilityLabel(L10n.text("可升级"))
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(selected ? Color(nsColor: ToolboxAppearance.selection) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }.padding(5)
            }
            .frame(minWidth: 160, idealWidth: 210, maxWidth: 225, maxHeight: .infinity)
            .toolboxCard()

            if let selected = packages.first(where: { $0.id == selection.wrappedValue }) {
                packageDetails(selected)
            } else {
                VStack(spacing: 8) {
                    WorkspaceGlyph(symbol: "shippingbox", tint: .accent, size: 44)
                    Text(L10n.text("选择一个包查看详情")).font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolboxCard()
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func packageDetails(_ package: BrewPackage) -> some View {
        let installed = model.installed.first { $0.id == package.id }
        let localVersions = installed?.installedVersions ?? []
        let isInstalled = installed != nil
        let canUpgrade = installed?.outdated == true
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    WorkspaceGlyph(symbol: package.kind == .formula ? "shippingbox.fill" : "macwindow", tint: .accent, size: 33)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(package.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(package.kind.title).font(.caption.weight(.medium)).foregroundStyle(WorkspaceTint.neutral.foreground)
                    }
                }
                if let description = package.description { Text(description).textSelection(.enabled) }
                if !localVersions.isEmpty {
                    LabeledContent(L10n.text("已安装"), value: localVersions.joined(separator: "、")).font(.callout)
                }
                if let version = package.availableVersion {
                    LabeledContent(L10n.text("当前发布版本"), value: version).font(.callout)
                }
                if let url = package.homepage, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    Link(L10n.text("软件包主页"), destination: url)
                }
                HStack {
                    if !isInstalled {
                        Button(L10n.text("安装"), systemImage: "arrow.down.to.line") { model.change(.install, package: package) }
                            .buttonStyle(WorkspaceActionStyle(tint: .accent, prominent: true))
                    }
                    if canUpgrade {
                        Button(L10n.text("升级"), systemImage: "arrow.up.circle") { model.change(.upgrade, package: package) }
                            .buttonStyle(WorkspaceActionStyle(tint: .accent, prominent: true))
                    }
                    if isInstalled {
                        Button(L10n.text("卸载"), systemImage: "trash") { removal = .package(package) }
                            .buttonStyle(WorkspaceActionStyle(tint: .danger))
                    }
                    if section == .search, package.availableVersion == nil {
                        Button(L10n.text("获取详情"), systemImage: "info.circle") { model.showDetails(package) }
                            .buttonStyle(WorkspaceActionStyle(tint: .neutral))
                    }
                }
                .disabled(model.busy)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolboxCard()
    }

    private var tapsView: some View {
        let name = tapName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                WorkspaceField(title: L10n.text("软件源，例如 user/repo"), symbol: "link", text: $tapName)
                Button(L10n.text("添加软件源"), systemImage: "plus") { model.changeTap(name, adding: true) }
                    .buttonStyle(WorkspaceActionStyle(prominent: true))
                    .disabled(model.busy || !HomebrewModel.validTap(name) || model.taps.contains(name))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.taps.isEmpty {
                        Text(L10n.text("暂无额外的软件源")).font(.callout).foregroundStyle(.secondary).padding()
                    }
                    ForEach(model.taps, id: \.self) { name in
                        HStack {
                            WorkspaceGlyph(symbol: "tray.full.fill", tint: .neutral)
                            Text(name).font(.system(.callout, design: .monospaced))
                            Spacer()
                            Button(L10n.text("移除"), systemImage: "minus.circle") { removal = .tap(name) }
                                .buttonStyle(WorkspaceActionStyle(tint: .danger)).disabled(model.busy)
                                .accessibilityLabel(L10n.text("移除 %@", name))
                        }.padding(10).toolboxCard()
                    }
                }.padding(1)
            }.frame(maxHeight: .infinity)
        }
    }

    private var diagnosticsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(L10n.text("brew 路径"), systemImage: "terminal").font(.subheadline.weight(.semibold))
                            .foregroundStyle(WorkspaceTint.accent.foreground)
                        Spacer()
                        Text(model.configuredPath.isEmpty ? L10n.text("自动检测") : L10n.text("手动配置"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        WorkspaceField(title: model.executable?.path ?? "/opt/homebrew/bin/brew",
                                       symbol: "folder", text: $pathDraft, tint: .accent, monospaced: true)
                            .accessibilityLabel(L10n.text("brew 路径"))
                            .onSubmit { applyPath() }
                        Button(L10n.text("应用"), systemImage: "checkmark", action: applyPath)
                            .buttonStyle(WorkspaceActionStyle(tint: .accent, prominent: true))
                            .disabled(model.busy || pathDraft.trimmingCharacters(in: .whitespacesAndNewlines) == model.configuredPath)
                        if !model.configuredPath.isEmpty {
                            Button(L10n.text("恢复自动"), systemImage: "arrow.uturn.backward") { model.applyExecutablePath("") }
                                .buttonStyle(WorkspaceActionStyle(tint: .neutral)).disabled(model.busy)
                        }
                    }
                }
                .padding(10).toolboxCard()
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    maintenanceTile(.update, symbol: "arrow.triangle.2.circlepath", tint: .accent, hint: L10n.text("同步软件包索引"))
                    maintenanceTile(.upgrade, symbol: "arrow.up.circle", tint: .accent, hint: L10n.text("批量更新已安装的软件"))
                    maintenanceTile(.doctor, symbol: "stethoscope", tint: .accent, hint: L10n.text("检查环境、权限和构建路径"))
                    maintenanceTile(.config, symbol: "slider.horizontal.3", tint: .neutral, hint: L10n.text("查看版本、架构和安装前缀"))
                    maintenanceTile(.previewCleanup, symbol: "magnifyingglass", tint: .neutral, hint: L10n.text("查看可移除的项目"))
                    maintenanceTile(.cleanup, symbol: "trash", tint: .danger, hint: L10n.text("清理旧版本与过期下载"))
                }
                .disabled(model.busy || model.executable == nil)
            }
            .padding(1)
        }
        .frame(maxHeight: .infinity)
    }

    private func applyPath() {
        let path = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path != model.configuredPath, !model.busy else { return }
        model.applyExecutablePath(path)
    }

    private func maintenanceTile(_ operation: BrewMaintenance, symbol: String, tint: WorkspaceTint, hint: String) -> some View {
        HStack(spacing: 8) {
            WorkspaceGlyph(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title).font(.system(size: 12, weight: .semibold))
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 1)
            Button(L10n.text("运行"), systemImage: "play.fill") {
                if operation == .upgrade || operation == .cleanup {
                    confirmation = operation
                } else {
                    model.perform(operation)
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(WorkspaceActionStyle(tint: tint))
            .help(operation.title)
            .accessibilityLabel(operation.title)
        }
        .padding(8)
        .toolboxCard(radius: 9)
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "terminal.fill").foregroundStyle(WorkspaceTerminal.accent).accessibilityHidden(true)
                Text(L10n.text("控制台")).font(.system(size: 12, weight: .semibold)).foregroundStyle(WorkspaceTerminal.foreground)
                Circle().fill(consoleStatus.color).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(consoleStatus.title).font(.caption).foregroundStyle(consoleStatus.color).lineLimit(1)
                Spacer(minLength: 0)
                Button(L10n.text("复制日志"), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.map(\.message).joined(), forType: .string)
                }
                .labelStyle(.iconOnly).help(L10n.text("复制日志"))
                .buttonStyle(WorkspaceActionStyle(tint: .neutral, onTerminal: true)).disabled(model.log.isEmpty)
                Button(L10n.text("清空"), action: model.clearLog)
                    .buttonStyle(WorkspaceActionStyle(tint: .neutral, onTerminal: true)).disabled(model.log.isEmpty)
                if model.busy {
                    Button(L10n.text("取消操作"), systemImage: "stop.fill", action: model.cancel)
                        .buttonStyle(WorkspaceActionStyle(tint: .danger, onTerminal: true)).disabled(model.isCancelling)
                }
                Button(consoleExpanded ? L10n.text("缩小控制台") : L10n.text("展开控制台"),
                       systemImage: consoleExpanded ? "chevron.down" : "chevron.up") { consoleExpanded.toggle() }
                    .labelStyle(.iconOnly)
                    .help(consoleExpanded ? L10n.text("缩小控制台") : L10n.text("展开控制台"))
                    .buttonStyle(WorkspaceActionStyle(tint: .neutral, onTerminal: true))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(WorkspaceTerminal.header)

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(WorkspaceTerminal.error).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(WorkspaceTerminal.error.opacity(0.12))
            }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(consoleTranscript)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end").accessibilityHidden(true)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 8)
                }
                .onAppear { reader.scrollTo("end", anchor: .bottom) }
                .onChange(of: model.log) { _, _ in reader.scrollTo("end", anchor: .bottom) }
                .onChange(of: consoleExpanded) { _, _ in reader.scrollTo("end", anchor: .bottom) }
            }
            .frame(height: consoleExpanded ? 180 : (section == .diagnostics ? 84 : 67))
        }
        .background(WorkspaceTerminal.background, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var consoleStatus: (title: String, color: Color) {
        if let activity = model.activity {
            return (model.isCancelling ? L10n.text("正在取消…") : activity, WorkspaceTerminal.accent)
        }
        switch model.outcome {
        case .success: return (L10n.text("操作完成"), WorkspaceTerminal.success)
        case .warning: return (L10n.text("有诊断警告"), WorkspaceTerminal.warning)
        case .failure: return (L10n.text("操作失败"), WorkspaceTerminal.error)
        case .cancelled: return (L10n.text("已取消"), WorkspaceTerminal.warning)
        case nil: return (L10n.text("待命"), WorkspaceTerminal.subdued)
        }
    }

    private var consoleTranscript: AttributedString {
        if model.log.isEmpty {
            var placeholder = AttributedString(L10n.text("暂无输出"))
            placeholder.foregroundColor = WorkspaceTerminal.subdued
            return placeholder
        }
        return model.log.reduce(into: AttributedString()) { result, entry in
            var part = AttributedString(entry.message)
            part.foregroundColor = switch entry.kind {
            case .command: WorkspaceTerminal.accent
            case .output: WorkspaceTerminal.foreground
            case .success: WorkspaceTerminal.success
            case .warning: WorkspaceTerminal.warning
            case .error: WorkspaceTerminal.error
            }
            result.append(part)
        }
    }
}
