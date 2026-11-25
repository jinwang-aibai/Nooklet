import AppKit
import NookletCore
import SwiftUI

@main
enum NookletMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var model: ToolboxModel?
    private var statusItem: NSStatusItem?
    private let catIcon = RunningCatStatusIcon()
    private let liveStatusItem = LiveStatusItem()
    private var windowController: ToolboxWindowController?
    private var popover: NSPopover?
    private weak var popoverAnchor: NSView?
    private var livePreviewVisible = false
    private var island: IslandController?
    private var islandMetrics: Set<StatusMetric> = []
    private let sampler = StatusSampler()
    private var startupError: Error?
    private var startupURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        NSApp.servicesProvider = self
        sampler.onUpdate = { [weak self] in self?.renderReadings() }
        do {
            let environment = ProcessInfo.processInfo.environment
            let override = environment["NOOKLET_DATA_DIR"] ?? environment["LITEBOX_DATA_DIR"]
            let paths = try AppPaths(rootDirectory: override.map { URL(fileURLWithPath: $0, isDirectory: true) })
            let instance = try ToolboxModel(paths: paths)
            instance.onChange = { [weak self] in self?.refresh() }
            instance.onAppearanceChange = { [weak self] in self?.applyAppearance() }
            instance.onError = { [weak self] error in self?.showError(error) }
            model = instance
            applyAppearance()
            try instance.restore()
            instance.menuBar.onSettings = { [weak self] in self?.show(.menuBar) }
            instance.menuBar.start()
        } catch {
            startupError = error
        }
        makeMainMenu()
        makeStatusItem()
        if startupError == nil { refresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if startupURLs.isEmpty || CommandLine.arguments.contains("--show-window") || model?.preferences.menuIconVisible == false {
            showToolbox()
        }
        let urls = startupURLs
        startupURLs.removeAll()
        handleFinderURLs(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.zsh.saving { return .terminateCancel }
        if model.zsh.hasDrafts || model.homebrew.changingSystem {
            let alert = NSAlert()
            alert.messageText = L10n.text("退出 Nooklet？")
            var details: [String] = []
            if model.zsh.hasDrafts { details.append(L10n.text("未保存的 Zsh 配置修改将被舍弃。")) }
            if model.homebrew.changingSystem { details.append(L10n.text("正在执行的 Homebrew 操作将被取消。")) }
            alert.informativeText = details.joined(separator: "\n")
            alert.addButton(withTitle: L10n.text("继续使用"))
            alert.addButton(withTitle: L10n.text("退出 Nooklet")).hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        guard model.homebrew.busy else { return .terminateNow }
        Task {
            await model.homebrew.cancelAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if model == nil, startupError == nil {
            startupURLs.append(contentsOf: urls)
            return
        }
        handleFinderURLs(urls)
    }

    private func handleFinderURLs(_ urls: [URL]) {
        for url in urls {
            do {
                if let request = try FinderRequest.take(at: url) { try performFinderRequest(request) }
            } catch {
                showError(error)
            }
        }
    }

    private func performFinderRequest(_ request: FinderRequest) throws {
        switch request {
        case .newFolder(let directory):
            NSWorkspace.shared.activateFileViewerSelecting([try FinderNewFile.createFolder(in: directory)])
        case .newFile(let format, let directory):
            NSWorkspace.shared.activateFileViewerSelecting([try format.create(in: directory)])
        case .openTerminal(let directory):
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Terminal.app"])
            }
            openFinderItems([directory], with: terminal)
        case .openWith(let app, let urls):
            guard !urls.isEmpty, let settings = try FinderToolsSettings.store.load(),
                  settings.enabled.contains(.openWith), settings.applications.contains(app) else { return }
            openFinderItems(urls, with: app.url)
        }
    }

    private func openFinderItems(_ urls: [URL], with app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.showError(error) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(model?.preferences.menuIconVisible == false ? .menuBar : nil)
        return false
    }

    private func makeMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Nooklet")
        let settings = appMenu.addItem(withTitle: L10n.text("设置…"), action: #selector(showToolbox), keyEquivalent: ",")
        settings.target = self
        let updates = appMenu.addItem(withTitle: L10n.text("检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = model != nil
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.text("退出 Nooklet"), action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: L10n.text("编辑"))
        for (title, selector, key) in [
            (L10n.text("撤销"), "undo:", "z"), (L10n.text("重做"), "redo:", "Z"),
            (L10n.text("剪切"), "cut:", "x"), (L10n.text("复制"), "copy:", "c"), (L10n.text("粘贴"), "paste:", "v"), (L10n.text("全选"), "selectAll:", "a"),
        ] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windows = NSMenu(title: L10n.text("窗口"))
        let close = NSMenuItem(title: L10n.text("关闭窗口"), action: #selector(closeToolbox), keyEquivalent: "w")
        close.target = self
        windows.addItem(close)
        windowItem.submenu = windows
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: max(32, NSStatusBar.system.thickness))
        catIcon.attach(to: item.button)
        item.button?.setAccessibilityLabel(L10n.text("Nooklet 系统状态"))
        item.button?.toolTip = L10n.text("Nooklet 系统状态 · 右键打开菜单")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked(_ button: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover?.performClose(nil)
            let menu = NSMenu()
            let tools = menu.addItem(withTitle: L10n.text("打开 Nooklet 设置…"), action: #selector(showToolbox), keyEquivalent: ",")
            tools.target = self
            if model != nil {
                let updates = menu.addItem(withTitle: L10n.text("检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "")
                updates.target = self
                let eject = menu.addItem(withTitle: L10n.text("一键推出磁盘"), action: #selector(ejectAllDisks), keyEquivalent: "")
                eject.target = self
                menu.addItem(.separator())
                for (title, kind) in [
                    (L10n.text("磁盘推出…"), PluginTemplate.diskEject), (L10n.text("Homebrew 管理…"), .homebrew),
                    (L10n.text("退出应用…"), .runningApps), (L10n.text("Zsh 配置…"), .zshConfiguration),
                ] {
                    let tool = menu.addItem(withTitle: title, action: #selector(showQuickTool(_:)), keyEquivalent: "")
                    tool.target = self
                    tool.representedObject = kind.rawValue
                }
            }
            menu.addItem(.separator())
            let importItem = menu.addItem(withTitle: L10n.text("导入本地插件…"), action: #selector(importPlugin), keyEquivalent: "")
            importItem.target = self
            let data = menu.addItem(withTitle: L10n.text("打开数据目录"), action: #selector(openDataDirectory), keyEquivalent: "")
            data.target = self
            menu.addItem(.separator())
            let quit = menu.addItem(withTitle: L10n.text("退出 Nooklet"), action: #selector(quitApplication), keyEquivalent: "")
            quit.target = self
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
            return
        }
        showStatus(from: button, edge: .minY)
    }

    private func showStatus(from anchor: NSView, edge: NSRectEdge, showsSettingsLink: Bool = true) {
        if let startupError { showError(startupError); return }
        guard let model, anchor.window != nil else { return }
        if let popover, popover.isShown {
            let sameAnchor = popoverAnchor === anchor
            popover.performClose(nil)
            if sameAnchor { return }
        }
        let openSettings: (() -> Void)? = showsSettingsLink ? { [weak self] in self?.show(.systemStatus) } : nil
        let view = StatusDashboard(model: model, sampler: sampler, onSettings: openSettings)
        let popover = NSPopover()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        popover.appearance = NSApp.appearance
        popover.contentSize = dashboardSize(model.preferences, on: anchor.window?.screen,
                                            showsSettingsLink: showsSettingsLink)
        popoverAnchor = anchor
        self.popover = popover
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
        configureSampling()
        renderReadings()
    }

    private func applyAppearance() {
        NSApp.appearance = model?.general.appearance
        popover?.appearance = NSApp.appearance
        windowController?.updateAppearance()
    }

    private func dashboardSize(_ preferences: DisplayPreferences, on screen: NSScreen?, showsSettingsLink: Bool) -> NSSize {
        let visibleHeight = screen?.visibleFrame.height ?? 790
        let height = StatusDashboard.preferredHeight(preferences, showsSettingsLink: showsSettingsLink)
        return NSSize(width: StatusDashboard.width,
                      height: min(max(160, visibleHeight - 35), height))
    }

    func popoverDidClose(_ notification: Notification) {
        if let closed = notification.object as? NSPopover, closed === popover {
            popover = nil
            popoverAnchor = nil
        }
        configureSampling()
    }

    private func refresh() {
        guard let model else { return }
        let preferences = model.preferences
        if let popover, popover.isShown,
           let view = (popover.contentViewController as? NSHostingController<StatusDashboard>)?.rootView {
            popover.contentSize = dashboardSize(preferences, on: popoverAnchor?.window?.screen,
                                                showsSettingsLink: view.onSettings != nil)
        }
        statusItem?.isVisible = preferences.menuIconVisible
        updateCatAnimation()
        liveStatusItem.configure(enabled: preferences.liveMenuEnabled && !preferences.menuBarMetrics.isEmpty) { [weak self] anchor in
            self?.statusItemClicked(anchor)
        }
        let desired = PluginTemplate.island.isEnabledInToolbox && preferences.islandEnabled ? preferences.island : []
        if desired != islandMetrics {
            island?.close()
            island = nil
            islandMetrics = desired
            if !desired.isEmpty {
                let instance = IslandController(metrics: desired)
                instance.onOpen = { [weak self] in self?.show(.island) }
                island = instance
            }
        }
        configureSampling()
        renderReadings()
        windowController?.render()
    }

    private func configureSampling() {
        guard let preferences = model?.preferences else { return }
        let dashboardVisible = popover?.isShown == true
        let dashboard = dashboardVisible ? preferences.menu : []
        let live = preferences.liveMenuEnabled || livePreviewVisible ? Set(preferences.menuBarMetrics) : []
        let cat: Set<StatusMetric> = animatesCat ? [.cpu] : []
        let cadence: TimeInterval = !live.isEmpty ? 1 : (!dashboard.isEmpty || !cat.isEmpty ? 2 : 5)
        let canOpenDashboard = preferences.menuIconVisible || (preferences.liveMenuEnabled && !preferences.menuBarMetrics.isEmpty)
        sampler.configure(metrics: dashboard.union(islandMetrics).union(live).union(cat),
                          backgroundMetrics: canOpenDashboard ? preferences.menu : [],
                          interval: cadence, dashboardVisible: dashboardVisible)
    }

    private var animatesCat: Bool {
        statusItem?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func updateCatAnimation() { catIcon.setAnimating(animatesCat) }

    @objc private func accessibilityDisplayChanged() {
        updateCatAnimation()
        configureSampling()
    }

    private func renderReadings() {
        let readings = sampler.snapshot.readings
        catIcon.update(cpuUsage: readings[.cpu]?.point)
        island?.render(readings)
        if let preferences = model?.preferences, preferences.liveMenuEnabled {
            liveStatusItem.render(LiveStatusMetric.items(preferences: preferences, readings: readings))
        }
    }

    @objc private func screensChanged() {
        island?.place()
        model?.menuBar.screenConfigurationChanged()
    }

    func applicationWillTerminate(_ notification: Notification) { model?.menuBar.stop() }
    @objc private func showToolbox() { show(nil) }

    private func show(_ kind: PluginTemplate?) {
        popover?.performClose(nil)
        if let startupError { showError(startupError); return }
        guard let model else { return }
        if windowController == nil {
            let controller = ToolboxWindowController(model: model, statusSampler: sampler)
            controller.onStatusPreview = { [weak self] anchor in
                self?.showStatus(from: anchor, edge: .maxX, showsSettingsLink: false)
            }
            controller.onLivePreviewVisibility = { [weak self] visible in
                self?.livePreviewVisible = visible
                self?.configureSampling()
            }
            controller.onClose = { [weak self] in self?.windowController = nil }
            controller.onQuit = { [weak self] in self?.quitApplication() }
            windowController = controller
        }
        if let kind { windowController?.showTool(kind) }
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController?.window?.makeKeyAndOrderFront(nil)
        windowController?.updateVisibility()
    }

    @objc private func showQuickTool(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let kind = PluginTemplate(rawValue: value) else { return }
        show(kind)
    }

    @objc private func ejectAllDisks() {
        guard let disks = model?.disks, !disks.working else { return }
        Task {
            await disks.ejectAll()
            if !disks.errors.isEmpty || !disks.didEject { show(.diskEject) }
        }
    }

    @objc private func closeToolbox() { windowController?.window?.close() }
    @objc private func checkForUpdates() {
        guard let model else { return }
        show(nil)
        windowController?.showGeneralSettings()
        model.softwareUpdate.check()
    }

    @objc private func quitApplication() { NSApp.terminate(nil) }

    @objc func copySelectedPaths(_ pasteboard: NSPasteboard, userData: String?,
                                 error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = serviceURLs(pasteboard)
        guard !urls.isEmpty else { error.pointee = L10n.text("请在 Finder 中选中文件。") as NSString; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc func shareSelectedFile(_ pasteboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = serviceURLs(pasteboard)
        guard !urls.isEmpty, let model else {
            error.pointee = L10n.text("请选择要共享的文件或文件夹。") as NSString
            return
        }
        show(.lanShare)
        model.lanShare.add(urls)
    }

    private func serviceURLs(_ pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty { return urls }
        let paths = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] ?? []
        return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
    }

    @objc private func importPlugin() {
        guard let model else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = L10n.text("导入本地插件")
        panel.prompt = L10n.text("导入")
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try model.importPlugin(from: url)
            show(imported.kind)
        } catch { showError(error) }
    }

    @objc private func openDataDirectory() {
        if let model { NSWorkspace.shared.open(model.paths.rootDirectory) }
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
