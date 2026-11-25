import AppKit
import CoreImage.CIFilterBuiltins
import NookletCore

@MainActor
final class LANSharePanel: ToolPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private struct Row {
        let name: String
        let directory: Bool
        var url: URL? = nil
        var id: UUID? = nil
        var size: Int64? = nil
        var unavailable = false
    }

    private let controller: LANShareController
    private let panelHeading: String
    private let enabled = NSSwitch()
    private let statusDot = LANStatusDot()
    private let status = shareLabel("", size: 12, color: .secondaryLabelColor)
    private let link = listLabel("", monospaced: true)
    private let interfaces = NSPopUpButton()
    private let refresh = NSButton()
    private let copyLinkButton = NSButton()
    private let qrButton = NSButton()
    private let networkButton = NSButton()
    private let tabs = NSSegmentedControl(labels: [L10n.text("文件与文件夹"), L10n.text("文本")], trackingMode: .selectOne, target: nil, action: nil)
    private let section = NSView()
    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let files = LANDropZone()
    private let text = NSView()
    private let editor = LANTextView()
    private let publish = NSButton()
    private let copyTextButton = NSButton()
    private let textState = shareLabel("", size: 12, color: .secondaryLabelColor)
    private let listState = shareLabel("", size: 12, color: .secondaryLabelColor)
    private let listEmpty = shareLabel("", size: 13, color: .secondaryLabelColor)
    private let emptyState = NSStackView()
    private let breadcrumb = shareLabel(L10n.text("共享目录"), size: 13, weight: .semibold)
    private let backButton = NSButton()
    private let dropSurface = LANFileDropSurface()
    private let dropFeedback = shareLabel(L10n.text("松手添加"), size: 13, weight: .medium, color: .controlAccentColor)
    private var listHeight: NSLayoutConstraint?
    private var isDropHighlighted = false
    private var emptyMessage = ""
    private var addresses: [InterfaceAddress] = []
    private var rows: [Row] = []
    private var openedRoot: LANShareEntry?
    private var trail: [String] = []
    private var listingTask: Task<Void, Never>?
    private var renderedEntries: [LANShareEntry]?
    private var renderedUnavailable = Set<UUID>()
    private var lastLink: URL?
    private var copyFeedback: Task<Void, Never>?
    private var popover: NSPopover?
    private var isLoading = false

    init(heading: String, controller: LANShareController) {
        self.controller = controller
        self.panelHeading = heading
        super.init(heading: heading, detail: "")
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        pinShareView(makeBody(), to: root, horizontal: 28, vertical: 24)
        view = root
    }

    override func makeBody() -> NSView {
        tabs.target = self
        tabs.action = #selector(switchTab)
        tabs.selectedSegment = 0
        tabs.segmentStyle = .rounded
        tabs.setImage(NSImage(systemSymbolName: "folder", accessibilityDescription: nil), forSegment: 0)
        tabs.setImage(NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil), forSegment: 1)
        tabs.setLabel(L10n.text("文件"), forSegment: 0)
        let service = buildService()
        buildFiles()
        buildText()
        pinShareView(files, to: section)
        pinShareView(text, to: section)

        let content = NSView()
        for child in [service, tabs, section] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            service.topAnchor.constraint(equalTo: content.topAnchor),
            service.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            service.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: service.bottomAnchor, constant: 19),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            section.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            section.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            section.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            section.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        editor.string = controller.draft
        controller.onChange = { [weak self] in self?.render() }
        reloadNetwork()
        switchTab()
        render()
        return content
    }

    private func buildService() -> NSView {
        enabled.target = self
        enabled.action = #selector(toggleService)
        enabled.setAccessibilityLabel(L10n.text("内网共享服务"))
        configureIcon(copyLinkButton, symbol: "document.on.document", label: L10n.text("复制链接"), action: #selector(copyLink))
        configureIcon(qrButton, symbol: "qrcode", label: L10n.text("显示二维码"), action: #selector(showQR))
        configureIcon(networkButton, symbol: "gearshape", label: L10n.text("网络设置"), action: #selector(showNetwork))
        configure(refresh, title: L10n.text("刷新"), symbol: "arrow.clockwise", action: #selector(reloadNetwork))
        interfaces.setAccessibilityLabel(L10n.text("共享网卡"))
        link.isSelectable = true
        link.setAccessibilityLabel(L10n.text("访问地址"))
        link.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        link.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let heading = panelTitle(panelHeading, symbol: symbol)
        statusDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        let connection = makeStack([statusDot, status, enabled], axis: .horizontal, spacing: 8)
        let header = makeStack([heading, shareSpacer(), connection], axis: .horizontal, spacing: 10)

        let addressIcon = shareIcon("link", size: 15, color: .secondaryLabelColor)
        let line = makeStack([addressIcon, link, copyLinkButton, qrButton, networkButton], axis: .horizontal, spacing: 7)
        line.distribution = .fill
        let address = shareSurface(line, inset: 8, radius: 10, tint: .muted)
        let service = makeStack([header, address], spacing: 13)
        for row in [header, address] { row.widthAnchor.constraint(equalTo: service.widthAnchor).isActive = true }
        return service
    }

    private func buildFiles() {
        configureIcon(backButton, symbol: "chevron.left", label: L10n.text("返回上一级"), action: #selector(goUp))
        let choose = NSButton()
        configureIcon(choose, symbol: "plus", label: L10n.text("添加文件或文件夹"), action: #selector(chooseItems))
        choose.toolTip = L10n.text("添加文件或文件夹，也可直接拖入")
        files.onDrop = { [weak self] urls in self?.add(urls) ?? false }
        files.onHighlight = { [weak self] highlighted in
            guard let self else { return }
            self.isDropHighlighted = highlighted
            self.renderDropState()
        }

        breadcrumb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        listState.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let line = makeStack([backButton, breadcrumb, shareSpacer(), listState, choose], axis: .horizontal, spacing: 7)

        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.rowHeight = 45
        table.intercellSpacing = .zero
        table.allowsEmptySelection = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openSelectedRow)
        table.setAccessibilityLabel(L10n.text("共享目录列表"))
        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        tableScroll.borderType = .noBorder
        tableScroll.drawsBackground = false
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.documentView = table
        pinShareView(tableScroll, to: dropSurface, horizontal: 2, vertical: 2)

        listEmpty.alignment = .center
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 10
        let mark = shareSurface(shareIcon("tray.and.arrow.down", size: 19, color: .controlAccentColor),
                                inset: 9, radius: 11, tint: .accent)
        emptyState.addArrangedSubview(mark)
        emptyState.addArrangedSubview(listEmpty)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        dropSurface.addSubview(emptyState)
        dropFeedback.translatesAutoresizingMaskIntoConstraints = false
        dropSurface.addSubview(dropFeedback)
        line.translatesAutoresizingMaskIntoConstraints = false
        dropSurface.translatesAutoresizingMaskIntoConstraints = false
        files.addSubview(line)
        files.addSubview(dropSurface)
        let height = dropSurface.heightAnchor.constraint(equalToConstant: 152)
        height.priority = .defaultHigh
        listHeight = height
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: files.topAnchor),
            line.leadingAnchor.constraint(equalTo: files.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: files.trailingAnchor),
            dropSurface.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 7),
            dropSurface.leadingAnchor.constraint(equalTo: files.leadingAnchor),
            dropSurface.trailingAnchor.constraint(equalTo: files.trailingAnchor),
            dropSurface.bottomAnchor.constraint(lessThanOrEqualTo: files.bottomAnchor),
            dropSurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            height,
            dropFeedback.centerXAnchor.constraint(equalTo: dropSurface.centerXAnchor),
            dropFeedback.centerYAnchor.constraint(equalTo: dropSurface.centerYAnchor),
            emptyState.centerXAnchor.constraint(equalTo: dropSurface.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: dropSurface.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: dropSurface.leadingAnchor, constant: 8),
        ])
    }

    private func buildText() {
        configure(publish, title: L10n.text("共享文本"), symbol: "arrow.up.right", action: #selector(publishText), primary: true)
        configureIcon(copyTextButton, symbol: "document.on.document", label: L10n.text("复制文本"), action: #selector(copyText))
        let paste = NSButton()
        configureIcon(paste, symbol: "clipboard", label: L10n.text("粘贴文本"), action: #selector(pasteText))
        textState.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = makeStack([textState, shareSpacer(), paste, copyTextButton, publish], axis: .horizontal, spacing: 7)
        editor.allowsUndo = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 9, height: 8)
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.delegate = self
        editor.setAccessibilityLabel(L10n.text("共享文本输入框"))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = editor
        let field = shareSurface(scroll, inset: 1, radius: 8, tint: .plain)
        let panel = NSView()
        layoutSections([field, footer], in: panel, gap: 10, growingIndex: 0)
        pinShareView(panel, to: text)
    }

    private func layoutSections(_ views: [NSView], in container: NSView, gap: CGFloat, growingIndex: Int = 2) {
        for (index, view) in views.enumerated() {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            let top = index == 0 ? container.topAnchor : views[index - 1].bottomAnchor
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: top, constant: index == 0 ? 0 : gap),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            if index == growingIndex {
                view.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            } else {
                view.setContentHuggingPriority(.required, for: .vertical)
                view.setContentCompressionResistancePriority(.required, for: .vertical)
            }
        }
        views.last?.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
    }

    @objc private func switchTab() {
        let showingText = tabs.selectedSegment == 1
        files.isHidden = showingText
        text.isHidden = !showingText
    }

    @objc private func chooseItems() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("添加到共享目录")
        panel.prompt = L10n.text("添加")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self, weak panel] result in
            if result == .OK, let panel { _ = self?.add(panel.urls) }
        }
    }

    @discardableResult
    private func add(_ urls: [URL]) -> Bool {
        let added = controller.add(urls)
        if added {
            openedRoot = nil
            trail.removeAll()
            loadRows()
        }
        return added
    }

    private func loadRows() {
        listingTask?.cancel()
        listingTask = nil
        isLoading = false
        if let root = openedRoot {
            let path = trail
            isLoading = true
            rows = []
            updateList()
            listingTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try root.children(at: path) }
                }.value
                guard let self, !Task.isCancelled else { return }
                self.isLoading = false
                switch result {
                case .success(let children):
                    let directory = path.reduce(root.url) { $0.appendingPathComponent($1) }
                    self.rows = children.map {
                        Row(name: $0.name, directory: $0.isDirectory,
                            url: directory.appendingPathComponent($0.name),
                            size: $0.isDirectory ? nil : $0.size)
                    }
                    self.updateList()
                case .failure:
                    self.updateList(emptyMessage: L10n.text("这个文件夹暂时无法打开。"))
                }
            }
        } else {
            rows = controller.settings.entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }.map {
                Row(name: $0.name, directory: $0.isDirectory, url: $0.url, id: $0.id,
                    unavailable: controller.unavailable.contains($0.id))
            }
            updateList()
        }
    }

    private func updateList(emptyMessage: String? = nil) {
        let path = [openedRoot?.name].compactMap { $0 } + trail
        let title = path.isEmpty ? L10n.text("共享目录") : ([L10n.text("共享目录")] + path).joined(separator: "  ›  ")
        breadcrumb.stringValue = title
        breadcrumb.toolTip = title
        backButton.isHidden = openedRoot == nil
        self.emptyMessage = emptyMessage ?? (isLoading ? L10n.text("正在读取…") : (openedRoot == nil ? L10n.text("拖入文件或文件夹") : L10n.text("空文件夹")))
        dropSurface.isEmpty = rows.isEmpty
        listHeight?.constant = rows.isEmpty ? 152 : table.rowHeight * CGFloat(rows.count) + 4
        renderDropState()
        listState.stringValue = controller.contentError ?? (isLoading ? "" : L10n.text("%@ 项", rows.count))
        listState.textColor = controller.contentError == nil ? .secondaryLabelColor : .systemOrange
        listState.toolTip = controller.contentError
        table.reloadData()
        if !rows.isEmpty { table.scrollRowToVisible(0) }
    }

    private func renderDropState() {
        dropSurface.highlighted = isDropHighlighted
        dropFeedback.isHidden = !isDropHighlighted
        emptyState.isHidden = !rows.isEmpty || isDropHighlighted
        tableScroll.isHidden = rows.isEmpty
        tableScroll.alphaValue = isDropHighlighted ? 0.16 : 1
        listEmpty.stringValue = emptyMessage
    }

    @objc private func goUp() {
        if trail.isEmpty { openedRoot = nil }
        else { trail.removeLast() }
        loadRows()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row index: Int) -> NSView? {
        let row = rows[index]
        let icon = shareIcon(row.directory ? "folder.fill" : "doc", size: 16,
                             color: row.directory ? .controlAccentColor : .secondaryLabelColor)
        let tile = shareSurface(icon, inset: 5, radius: 7, tint: row.directory ? .accent : .muted)
        let name: NSView
        if row.directory {
            let button = NSButton(title: row.name, target: self, action: #selector(openFolder))
            button.isBordered = false
            button.alignment = .left
            button.lineBreakMode = .byTruncatingMiddle
            button.attributedTitle = NSAttributedString(string: row.name, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
            ])
            button.tag = index
            button.toolTip = L10n.text("打开 %@", row.name)
            name = button
        } else {
            name = shareLabel(row.name, size: 13, weight: .medium)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var actions: [NSView] = [tile, name, shareSpacer()]
        if row.unavailable {
            let warning = shareIcon("exclamationmark.triangle", size: 13, color: .systemOrange)
            warning.toolTip = L10n.text("暂不可用")
            warning.setAccessibilityLabel(L10n.text("暂不可用"))
            actions.append(warning)
        } else if let size = row.size {
            let detail = shareLabel(ByteCountFormatter.string(fromByteCount: size, countStyle: .file), size: 11, color: .secondaryLabelColor)
            detail.setContentCompressionResistancePriority(.required, for: .horizontal)
            actions.append(detail)
        }
        if row.directory {
            let button = NSButton()
            configureIcon(button, symbol: "chevron.right", label: L10n.text("打开 %@", row.name), action: #selector(openFolder), size: 22)
            button.tag = index
            actions.append(button)
        }
        if let id = row.id {
            let remove = NSButton()
            configureIcon(remove, symbol: "xmark", label: L10n.text("移除 %@", row.name), action: #selector(removeItem), size: 22)
            remove.toolTip = L10n.text("从共享目录移除")
            remove.identifier = .init(id.uuidString)
            actions.append(remove)
        }
        let line = makeStack(actions, axis: .horizontal, spacing: 7)
        line.distribution = .fill
        let cell = LANShareCell()
        pinShareView(line, to: cell, horizontal: 10, vertical: 4)
        guard index < rows.count - 1 else { return cell }
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            separator.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        return cell
    }

    @objc private func openSelectedRow() {
        let index = table.clickedRow
        guard rows.indices.contains(index) else { return }
        if rows[index].directory { openRow(index) }
        else if let url = rows[index].url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func openFolder(_ sender: NSButton) { openRow(sender.tag) }

    private func openRow(_ index: Int) {
        guard rows.indices.contains(index), rows[index].directory else { return }
        if let id = rows[index].id {
            openedRoot = controller.settings.entries.first { $0.id == id }
            trail = []
        } else {
            trail.append(rows[index].name)
        }
        loadRows()
    }

    @objc private func removeItem(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        controller.remove(id)
    }

    func textDidChange(_ notification: Notification) {
        controller.draft = editor.string
        editor.needsDisplay = true
        renderText()
    }

    @objc private func pasteText() {
        view.window?.makeFirstResponder(editor)
        editor.paste(nil)
    }

    @objc private func copyText() {
        guard !editor.string.isEmpty else { return }
        if editor.selectedRange().length > 0 { editor.copy(nil) }
        else { writeToPasteboard(editor.string) }
        textState.stringValue = L10n.text("已复制")
    }

    @objc private func publishText() { controller.publishText() }

    private func renderText() {
        let changed = controller.draft != controller.settings.text
        publish.title = changed && controller.draft.isEmpty ? L10n.text("移除共享") : L10n.text("共享文本")
        publish.isEnabled = changed
        publish.bezelColor = changed ? .controlAccentColor : nil
        copyTextButton.isEnabled = !controller.draft.isEmpty
        let message = changed ? L10n.text("有未共享的修改") : (controller.settings.text.isEmpty ? L10n.text("尚未共享") : (controller.link == nil ? L10n.text("已保存") : L10n.text("已共享")))
        textState.stringValue = controller.contentError ?? message
        textState.toolTip = controller.contentError
        textState.textColor = controller.contentError == nil ? .secondaryLabelColor : .systemOrange
    }

    @objc private func reloadNetwork() {
        let previous = addresses.indices.contains(interfaces.indexOfSelectedItem) ? addresses[interfaces.indexOfSelectedItem].address : nil
        addresses = ((try? IPAddresses.local()) ?? []).filter { !$0.isIPv6 && LANShare.isPrivateIPv4($0.address) }
        addresses.sort { lhs, rhs in
            let l = lhs.interface.hasPrefix("en")
            let r = rhs.interface.hasPrefix("en")
            return l != r ? l : lhs.interface.localizedStandardCompare(rhs.interface) == .orderedAscending
        }
        interfaces.removeAllItems()
        if addresses.isEmpty { interfaces.addItem(withTitle: L10n.text("无可用的局域网地址")) }
        else {
            interfaces.addItems(withTitles: addresses.map { "\($0.interface) · \($0.address)" })
            if let index = addresses.firstIndex(where: { $0.address == (controller.address ?? previous) }) {
                interfaces.selectItem(at: index)
            }
        }
        render()
    }

    @objc private func toggleService() {
        if controller.isRunning { controller.stop(); return }
        reloadNetwork()
        let index = interfaces.indexOfSelectedItem
        guard addresses.indices.contains(index) else { return }
        controller.start(address: addresses[index].address)
    }

    @objc private func copyLink() {
        guard let url = controller.link else { return }
        writeToPasteboard(url.absoluteString)
        copyFeedback?.cancel()
        setCopyFeedback(copied: true)
        copyFeedback = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.setCopyFeedback(copied: false)
        }
    }

    private func setCopyFeedback(copied: Bool) {
        copyLinkButton.image = NSImage(systemSymbolName: copied ? "checkmark" : "document.on.document", accessibilityDescription: nil)
        copyLinkButton.toolTip = copied ? L10n.text("已复制") : L10n.text("复制链接")
        copyLinkButton.setAccessibilityLabel(copyLinkButton.toolTip)
    }

    @objc private func showQR() {
        guard let url = controller.link else { return }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let raw = filter.outputImage, let cg = CIContext().createCGImage(raw.transformed(by: .init(scaleX: 5, y: 5)),
                                                                               from: raw.extent.applying(.init(scaleX: 5, y: 5))) else { return }
        let image = NSImageView(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        image.imageScaling = .scaleNone
        image.widthAnchor.constraint(equalToConstant: CGFloat(cg.width + 20)).isActive = true
        image.heightAnchor.constraint(equalToConstant: CGFloat(cg.height + 20)).isActive = true
        image.wantsLayer = true
        image.layer?.backgroundColor = NSColor.white.cgColor
        image.layer?.cornerRadius = 8
        image.setAccessibilityLabel(L10n.text("访问二维码"))
        let title = shareLabel(L10n.text("用手机相机扫码"), size: 14, weight: .semibold)
        let hint = shareLabel(L10n.text("手机和 Mac 需在同一网络"), size: 12, color: .secondaryLabelColor)
        let stack = makeStack([title, image, hint], spacing: 9)
        stack.alignment = .centerX
        showPopover(stack, from: qrButton)
    }

    @objc private func showNetwork() {
        // The controls are reused; close the previous popover before reparenting them.
        popover?.close()
        interfaces.removeFromSuperview()
        refresh.removeFromSuperview()
        reloadNetwork()
        let title = shareLabel(L10n.text("访问网络"), size: 14, weight: .semibold)
        let hint = shareLabel(controller.isRunning ? L10n.text("关闭服务后可以切换网卡。") : L10n.text("选择与接收设备相连的网卡。"), size: 12, color: .secondaryLabelColor)
        showPopover(makeStack([title, makeStack([interfaces, refresh], axis: .horizontal, spacing: 8), hint], spacing: 8),
                    from: networkButton)
    }

    private func showPopover(_ content: NSView, from anchor: NSView) {
        popover?.close()
        let root = NSView()
        pinShareView(content, to: root, horizontal: 14, vertical: 13)
        let vc = NSViewController()
        vc.view = root
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        pop.contentViewController = vc
        pop.contentSize = root.fittingSize
        popover = pop
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func render() {
        let url = controller.link
        enabled.state = controller.isRunning ? .on : .off
        enabled.isEnabled = controller.isRunning || !addresses.isEmpty
        interfaces.isEnabled = !controller.isRunning && !addresses.isEmpty
        refresh.isEnabled = !controller.isRunning
        copyLinkButton.isEnabled = url != nil
        qrButton.isEnabled = url != nil
        if url != lastLink {
            copyFeedback?.cancel()
            setCopyFeedback(copied: false)
            if url == nil { popover?.close() }
            lastLink = url
        }
        status.stringValue = url != nil ? L10n.text("共享中") : (controller.isRunning ? L10n.text("开启中") : L10n.text("已关闭"))
        statusDot.tint = url != nil ? .systemGreen : (controller.isRunning ? .systemOrange : .tertiaryLabelColor)
        status.toolTip = url == nil ? nil : L10n.text("同一局域网内的设备可访问")
        let error = controller.connectionError ?? (addresses.isEmpty ? L10n.text("未找到局域网地址") : nil)
        link.stringValue = url?.absoluteString ?? error ?? L10n.text("开启后显示地址")
        link.textColor = url != nil ? .labelColor : (error == nil ? .secondaryLabelColor : .systemOrange)
        link.toolTip = url?.absoluteString ?? error
        if renderedEntries != controller.settings.entries || renderedUnavailable != controller.unavailable {
            renderedEntries = controller.settings.entries
            renderedUnavailable = controller.unavailable
            if let root = openedRoot, !controller.settings.entries.contains(root) {
                openedRoot = nil
                trail.removeAll()
            }
            loadRows()
        } else {
            listState.stringValue = controller.contentError ?? (isLoading ? "" : L10n.text("%@ 项", rows.count))
            listState.textColor = controller.contentError == nil ? .secondaryLabelColor : .systemOrange
            listState.toolTip = controller.contentError
        }
        renderText()
    }

    override func endUse() {
        listingTask?.cancel()
        copyFeedback?.cancel()
        popover?.close()
    }

    private func configure(_ button: NSButton, title: String, symbol: String, action: Selector,
                           primary: Bool = false, accessibility: String? = nil) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .regular
        if primary { button.bezelColor = .controlAccentColor }
        if let accessibility { button.setAccessibilityLabel(accessibility) }
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureIcon(_ button: NSButton, symbol: String, label: String, action: Selector, size: CGFloat = 28) {
        configure(button, title: "", symbol: symbol, action: action, accessibility: label)
        button.bezelStyle = .accessoryBarAction
        if size < 28 {
            button.isBordered = false
            button.image = button.image?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            button.contentTintColor = .secondaryLabelColor
        }
        button.widthAnchor.constraint(equalToConstant: size).isActive = true
        button.heightAnchor.constraint(equalToConstant: size).isActive = true
        button.toolTip = label
    }

    private func writeToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
