import AppKit
import FinderSync
import NookletCore
import UniformTypeIdentifiers

@MainActor
final class FinderToolsPanel: ToolPanel {
    private var settings = FinderToolsSettings()
    private var switches: [FinderAction: NSSwitch] = [:]
    private let status = NSTextField(wrappingLabelWithString: "")
    private let applications = makeStack([], spacing: 7)
    private let hasExtension = Bundle.main.builtInPlugInsURL
        .map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("NookletFinderExtension.appex").path) } == true

    override func makeBody() -> NSView {
        let manage = NSButton(title: L10n.text("打开扩展设置…"), target: self, action: #selector(openExtensionSettings))
        manage.isEnabled = hasExtension
        manage.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let directory = group(L10n.text("目录操作"), actions: [.newFolder, .newFile, .openTerminal])
        let copy = group(L10n.text("复制菜单项"), actions: [.copyName, .copyAbsolutePath, .copyRelativePath, .copyEscapedPath, .copyFileURL])
        let openWith = group(L10n.text("应用列表"), actions: [.openWith], extra: [
            applications,
            NSButton(title: L10n.text("添加应用…"), target: self, action: #selector(addApplication)),
        ])
        let quickCopy = NSButton(title: L10n.text("选择文件并复制路径…"), target: self, action: #selector(copyPaths))
        let groups = [directory, copy, openWith]
        let statusRow = makeStack([status, manage], axis: .horizontal)
        let stack = makeStack([statusRow] + groups + [quickCopy], spacing: 18)
        statusRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        for group in groups { group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = NSView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -6),
        ])

        do {
            settings = try FinderToolsSettings.store.load() ?? FinderToolsSettings()
        } catch {
            status.stringValue = L10n.text("无法读取右键工具设置")
            status.toolTip = error.localizedDescription
            for toggle in switches.values { toggle.isEnabled = false }
        }
        refreshExtensionStatus()
        renderSettings()
        return scroll
    }

    override func setVisible(_ visible: Bool) {
        if visible, isViewLoaded { refreshExtensionStatus() }
    }

    private func refreshExtensionStatus() {
        guard status.toolTip == nil else { return }
        guard hasExtension else {
            status.stringValue = L10n.text("请从打包的 Nooklet.app 启用 Finder 扩展")
            return
        }
        status.stringValue = FIFinderSyncController.isExtensionEnabled
            ? L10n.text("Finder 扩展已启用")
            : L10n.text("请在系统设置的「访达」或「文件提供程序」中启用 Nooklet")
    }

    private func group(_ title: String, actions: [FinderAction], extra: [NSView] = []) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let rows = actions.map(makeRow)
        let cardContent = makeStack(rows + extra, spacing: 0)
        for row in rows { row.widthAnchor.constraint(equalTo: cardContent.widthAnchor).isActive = true }
        if !extra.isEmpty {
            cardContent.setCustomSpacing(9, after: rows[0])
            cardContent.setCustomSpacing(9, after: applications)
            applications.widthAnchor.constraint(equalTo: cardContent.widthAnchor).isActive = true
        }

        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 12
        card.borderWidth = 0
        card.fillColor = ToolboxAppearance.card
        card.contentViewMargins = .zero
        if let content = card.contentView {
            cardContent.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(cardContent)
            NSLayoutConstraint.activate([
                cardContent.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),
                cardContent.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -7),
                cardContent.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 15),
                cardContent.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -15),
            ])
        }
        let group = makeStack([heading, card], spacing: 7)
        card.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }

    private func makeRow(_ action: FinderAction) -> NSView {
        let label = NSTextField(labelWithString: action.title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.setAccessibilityLabel(action.title)
        toggle.target = self
        toggle.action = #selector(changeAction(_:))
        switches[action] = toggle

        let labels: [NSView]
        if let detail = action.detail {
            let subtitle = NSTextField(labelWithString: detail)
            subtitle.font = .systemFont(ofSize: 11)
            subtitle.textColor = .secondaryLabelColor
            labels = [label, subtitle]
        } else {
            labels = [label]
        }
        let row = makeStack([makeStack(labels, spacing: 3), NSView(), toggle], axis: .horizontal)
        row.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        return row
    }

    private func renderSettings() {
        for (action, toggle) in switches {
            toggle.state = settings.enabled.contains(action) ? .on : .off
        }
        for row in applications.arrangedSubviews { row.removeFromSuperview() }
        if settings.applications.isEmpty {
            let empty = NSTextField(labelWithString: L10n.text("添加应用后，Finder 才会显示「用应用打开」子菜单。"))
            empty.textColor = .secondaryLabelColor
            applications.addArrangedSubview(empty)
            return
        }
        for (index, app) in settings.applications.enumerated() {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: app.url.path))
            icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
            let label = listLabel(app.name)
            label.toolTip = app.url.path
            let remove = NSButton(title: L10n.text("移除"), target: self, action: #selector(removeApplication(_:)))
            remove.tag = index
            remove.setAccessibilityLabel(L10n.text("移除 %@", app.name))
            let row = makeStack([icon, label, NSView(), remove], axis: .horizontal, spacing: 8)
            applications.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: applications.widthAnchor).isActive = true
        }
    }

    private func save(_ update: (inout FinderToolsSettings) -> Void) {
        do {
            var updated = try FinderToolsSettings.store.load() ?? FinderToolsSettings()
            update(&updated)
            try FinderToolsSettings.store.save(updated)
            settings = updated
        } catch {
            NSAlert(error: error).runModal()
        }
        renderSettings()
    }

    @objc private func openExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    @objc private func changeAction(_ sender: NSSwitch) {
        guard let action = switches.first(where: { $0.value === sender })?.key else { return }
        save { settings in
            if sender.state == .on { settings.enabled.insert(action) }
            else { settings.enabled.remove(action) }
        }
    }

    @objc private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("添加")
        guard panel.runModal() == .OK else { return }
        let apps = panel.urls.map { url in
            let displayName = FileManager.default.displayName(atPath: url.path)
            let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
            return FinderOpenApplication(url: url.standardizedFileURL, name: name)
        }
        save { settings in
            for app in apps where !settings.applications.contains(where: { $0.url == app.url }) {
                settings.applications.append(app)
            }
        }
    }

    @objc private func removeApplication(_ sender: NSButton) {
        guard settings.applications.indices.contains(sender.tag) else { return }
        let url = settings.applications[sender.tag].url
        save { $0.applications.removeAll { $0.url == url } }
    }

    @objc private func copyPaths() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("复制路径")
        guard panel.runModal() == .OK else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(panel.urls.map(\.path).joined(separator: "\n"), forType: .string)
    }
}
