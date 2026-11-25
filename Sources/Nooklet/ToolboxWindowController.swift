import AppKit
import NookletCore

@MainActor
final class ToolboxWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private final class ToolRow: NSTableRowView {
        override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
        var general = GeneralPreferences() { didSet { needsDisplay = true } }

        override func drawSelection(in dirtyRect: NSRect) {
            guard isSelected else { return }
            general.tint(ToolboxAppearance.selection, amount: 0.18).setFill()
            let rect = bounds.insetBy(dx: 2, dy: 2)
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            (general.accent ?? ToolboxAppearance.blue).setFill()
            let marker = NSRect(x: rect.minX + 4, y: rect.midY - 7, width: 3, height: 14)
            NSBezierPath(roundedRect: marker, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private enum SidebarRow: Equatable {
        case tool(Entry)
        case unavailableHeading

        var tool: Entry? {
            guard case let .tool(entry) = self else { return nil }
            return entry
        }

        var isSelectable: Bool { tool?.isEnabled == true }
    }

    private struct Entry: Equatable {
        let id: String?
        let name: String
        let details: String
        let kind: PluginTemplate?

        var isEnabled: Bool { kind?.isEnabledInToolbox ?? true }

        var icon: String {
            switch kind {
            case .systemStatus: "chart.bar.xaxis"
            case .ipLookup: "network"
            case .storageAnalysis: "internaldrive"
            case .lanShare: "arrow.up.right.square"
            case .menuBar: "menubar.rectangle"
            case .cooling: "fan"
            case .finderTools: "cursorarrow.click.2"
            case .appDiagnostics: "checkmark.shield"
            case .island: "capsule.portrait"
            case .diskEject: "eject.circle"
            case .homebrew: "shippingbox"
            case .runningApps: "power"
            case .zshConfiguration: "terminal"
            case .countdown: "timer"
            case nil: "gearshape"
            }
        }
    }

    private let model: ToolboxModel
    private let statusSampler: StatusSampler
    private let tools = NSTableView()
    private let sidebar = NSBox()
    private let detailView = NSView()
    private var rows: [SidebarRow] = []
    private var entry: Entry?
    private(set) var activePanel: ToolPanel?
    private var observers: [NSObjectProtocol] = []
    var onStatusPreview: ((NSView) -> Void)?
    var onLivePreviewVisibility: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var onQuit: (() -> Void)?

    init(model: ToolboxModel, statusSampler: StatusSampler) {
        self.model = model
        self.statusSampler = statusSampler
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 896, height: 656),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L10n.text("Nooklet 设置")
        window.backgroundColor = ToolboxAppearance.window
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 740, height: 525)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
        updateAppearance()
        observeVisibility()
        render()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        tools.style = .plain
        tools.backgroundColor = .clear
        tools.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tools.intercellSpacing = NSSize(width: 0, height: 1)
        tools.headerView = nil
        tools.rowHeight = 35
        tools.usesAlternatingRowBackgroundColors = false
        tools.allowsEmptySelection = false
        tools.dataSource = self
        tools.delegate = self
        tools.setAccessibilityLabel(L10n.text("设置分类"))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tool"))
        column.resizingMask = .autoresizingMask
        tools.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = tools
        let heading = NSTextField(labelWithString: "Nooklet")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        heading.textColor = ToolboxAppearance.ink
        let mark = NSImageView(image: NSApp.applicationIconImage)
        mark.widthAnchor.constraint(equalToConstant: 25).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 25).isActive = true
        let brand = makeStack([mark, heading], axis: .horizontal, spacing: 8)
        sidebar.boxType = .custom
        sidebar.borderWidth = 0
        sidebar.contentViewMargins = .zero
        let divider = NSBox()
        divider.boxType = .custom
        divider.fillColor = ToolboxAppearance.rule
        divider.borderWidth = 0
        divider.translatesAutoresizingMaskIntoConstraints = false
        for view in [brand, scroll, sidebar, detailView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        content.addSubview(sidebar)
        content.addSubview(detailView)
        content.addSubview(divider)
        sidebar.addSubview(brand)
        sidebar.addSubview(scroll)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 190),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            detailView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detailView.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            detailView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 44),
            scroll.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),
        ])
    }

    func updateAppearance() {
        let general = model.general
        window?.backgroundColor = general.tint(ToolboxAppearance.window, amount: 0.045)
        sidebar.fillColor = general.tint(ToolboxAppearance.sidebar, amount: 0.075)
        for index in rows.indices {
            (tools.rowView(atRow: index, makeIfNecessary: false) as? ToolRow)?.general = general
        }
    }

    func render() {
        var entries = [Entry(id: nil, name: L10n.text("基础信息"), details: "", kind: nil)]
        let order: [PluginTemplate] = [.systemStatus, .menuBar, .lanShare, .finderTools, .ipLookup, .storageAnalysis,
                                       .diskEject, .homebrew, .runningApps, .zshConfiguration, .island, .cooling, .appDiagnostics]
        for kind in order {
            entries += model.plugins.filter { $0.kind == kind }.map {
                let bundled = $0.id.hasPrefix("local.nooklet.")
                let name = $0.id == "local.nooklet.menu-bar" ? "菜单栏管理" : $0.name
                return Entry(id: $0.id, name: bundled ? L10n.text(name) : name,
                             details: bundled ? L10n.text($0.description) : $0.description, kind: kind)
            }
        }
        var updated = entries.filter(\.isEnabled).map(SidebarRow.tool)
        let unavailable = entries.filter { !$0.isEnabled }
        if !unavailable.isEmpty {
            updated.append(.unavailableHeading)
            updated.append(contentsOf: unavailable.map(SidebarRow.tool))
        }
        if updated != rows {
            let previousID = entry?.id
            rows = updated
            tools.reloadData()
            if let row = rows.firstIndex(where: { $0.isSelectable && $0.tool?.id == previousID })
                ?? rows.firstIndex(where: \.isSelectable),
               let tool = rows[row].tool {
                tools.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                select(tool)
            }
        }
        (activePanel as? DisplaySettingsPanel)?.refresh()
        (activePanel as? MenuBarPanel)?.render()
    }

    func showTool(_ kind: PluginTemplate) {
        guard kind.isEnabledInToolbox, let row = rows.firstIndex(where: { $0.tool?.kind == kind }),
              let tool = rows[row].tool else { return }
        tools.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        select(tool)
        tools.scrollRowToVisible(row)
        (activePanel as? SystemStatusPanel)?.showDashboardSettings()
    }

    func showGeneralSettings() {
        guard let tool = rows.first?.tool else { return }
        tools.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        select(tool)
        tools.scrollRowToVisible(0)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows[row] == .unavailableHeading
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row] == .unavailableHeading ? 34 : tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = rows[row].tool else {
            let title = shareLabel(L10n.text("暂未开放"), size: 11, weight: .semibold, color: ToolboxAppearance.secondary)
            let section = makeStack([title], axis: .horizontal)
            section.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 0, right: 8)
            return section
        }
        let enabled = item.isEnabled
        let icon = shareIcon(item.icon, size: 13, color: enabled ? ToolboxAppearance.blue : .tertiaryLabelColor)
        icon.setAccessibilityElement(false)
        let title = listLabel(item.name)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        if !enabled {
            title.textColor = ToolboxAppearance.secondary
            title.setAccessibilityLabel(L10n.text("%@，暂未开放", item.name))
            title.toolTip = L10n.text("暂未开放")
        }
        let row = makeStack([icon, title], axis: .horizontal, spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 13, bottom: 0, right: 8)
        return row
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ToolRow()
        view.general = model.general
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if rows.indices.contains(tools.selectedRow), let tool = rows[tools.selectedRow].tool { select(tool) }
    }

    private func select(_ selected: Entry) {
        guard selected.isEnabled, selected != entry else { return }
        activePanel?.endUse()
        activePanel?.view.removeFromSuperview()
        entry = selected

        let next: ToolPanel
        switch selected.kind {
        case nil: next = GeneralSettingsPanel(model: model)
        case .systemStatus:
            let settings = SystemStatusPanel(model: model, sampler: statusSampler)
            settings.onPreview = { [weak self] anchor in self?.onStatusPreview?(anchor) }
            settings.onLivePreviewVisibility = { [weak self] visible in self?.onLivePreviewVisibility?(visible) }
            next = settings
        case .island: next = DisplaySettingsPanel(model: model)
        case .menuBar: next = MenuBarPanel(model: model)
        case .lanShare: next = LANSharePanel(heading: selected.name, controller: model.lanShare)
        case .finderTools: next = FinderToolsPanel(heading: selected.name, detail: selected.details)
        case .ipLookup: next = IPPanel(heading: selected.name, paths: model.paths)
        case .storageAnalysis: next = StoragePanel(heading: selected.name, browser: model.storageBrowser)
        case .diskEject: next = DiskEjectPanel(heading: selected.name, detail: selected.details, model: model.disks)
        case .homebrew: next = HomebrewPanel(heading: selected.name, detail: selected.details, model: model.homebrew)
        case .runningApps:
            next = RunningAppsPanel(heading: selected.name, detail: selected.details) { [weak self] in self?.onQuit?() }
        case .zshConfiguration: next = ZshConfigurationPanel(heading: selected.name, detail: selected.details, model: model.zsh)
        case .countdown, .cooling, .appDiagnostics: return
        }
        next.symbol = selected.icon
        let view = next.view
        view.translatesAutoresizingMaskIntoConstraints = false
        detailView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: detailView.topAnchor),
            view.bottomAnchor.constraint(equalTo: detailView.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: detailView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: detailView.trailingAnchor),
        ])
        activePanel = next
        updateVisibility()
    }

    func updateVisibility() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        activePanel?.setVisible(visible)
    }

    private func observeVisibility() {
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            })
        }
    }

    func windowWillClose(_ notification: Notification) {
        activePanel?.endUse()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        onClose?()
    }
}
