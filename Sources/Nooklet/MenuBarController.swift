import AppKit
import Carbon
@preconcurrency import ApplicationServices
import NookletCore
import NookletMenuBarBridge

@MainActor
final class MenuBarController: NSObject {
    private struct Settings: Codable {
        var enabled = false
        var rules: [String: MenuBarVisibility] = [:]
    }

    private struct VisibilityConfiguration: Equatable {
        var apps: [String]
        var showsInputMenu: Bool
    }

    private struct ExpansionTrigger {
        let anchor: CGRect
        let screen: NSScreen
    }

    private let store: LocalJSONStore<Settings>
    private var settings = Settings()
    private let appID = Bundle.main.bundleIdentifier ?? "dev.local.Nooklet"
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var scan: Task<Void, Never>?
    private var assertion: NSObject?
    private var currentConfiguration: VisibilityConfiguration?
    private var applying = false
    private var pendingRescan = false
    private var needsPermissionNotice = false
    private var failed = false
    private var watchInventory = false
    private var hasScan = false
    private var runningIDs = Set<String>()
    private var expansion = MenuBarExpansion.collapsed
    private var nativeExpansion = MenuBarExpansion.collapsed
    private var arranging = false
    private var nativeLeft: [String: Bool] = [:]
    private var expansionTask: Task<Void, Never>?
    private var arrangementPanel: MenuBarArrangementPanel?
    private var contextTrigger: ExpansionTrigger?
    private var lastArrowClick: (time: TimeInterval, display: CGRect)?

    static let showAllTitle = L10n.text("展开全部（含始终隐藏）")
    private static let expandLabel = L10n.text("展开隐藏的菜单栏图标")
    private static let collapseLabel = L10n.text("收起菜单栏图标")

    private(set) var apps: [MenuBarApp] = []
    private(set) var message: String?
    var onChange: (() -> Void)?
    var onSettings: (() -> Void)?

    var enabled: Bool { settings.enabled }
    var trusted: Bool { AXIsProcessTrusted() }
    var supported: Bool { NookletMenuBarCanRestrict() }
    var scanning: Bool { scan != nil }
    var applyingRules: Bool { applying }
    var canVerifyRules: Bool { enabled && canHide && trusted && hasScan && !failed && !applying && !arranging }
    var editableApps: [MenuBarApp] { canHide && trusted ? apps.filter(\.canMove) : [] }

    // MenuBarAgent matches the allow-list against the copy registered in /Applications.
    var canHide: Bool {
        guard supported, let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) else { return false }
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return running.path.hasPrefix("/Applications/") && running == installed.resolvingSymlinksInPath()
    }

    init(paths: AppPaths) {
        store = LocalJSONStore(url: paths.rootDirectory.appendingPathComponent("menu-bar.json"))
        super.init()
        do { settings = try store.load() ?? Settings() }
        catch { message = L10n.text("无法读取菜单栏设置。%@", error.localizedDescription) }
    }

    func start() {
        if enabled { installButton() }
        updateTimer()
        refresh()
    }

    func setWatching(_ watching: Bool) {
        if watchInventory != watching {
            watchInventory = watching
            updateTimer()
        }
        // Returning from System Settings can make the same panel key again
        // without any visibility transition.
        if watching { refresh() }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        var next = settings
        next.enabled = enabled
        guard save(next) else { return }
        failed = false
        message = nil
        if enabled { installButton() }
        collapse()
        if enabled { refresh() }
        else { removeButton() }
        updateTimer()
        onChange?()
    }

    func rule(_ app: MenuBarApp) -> MenuBarVisibility { settings.rules[app.id] ?? .visible }

    func setRule(_ rule: MenuBarVisibility, for id: String) {
        guard editableApps.contains(where: { $0.id == id && self.rule($0) != rule }) else { return }
        var next = settings
        next.rules[id] = rule == .visible ? nil : rule
        guard save(next) else { return }
        failed = false
        message = nil
        collapse()
        onChange?()
    }

    func verifyRules(_ level: MenuBarExpansion) {
        guard canVerifyRules else { return }
        if level == .collapsed {
            collapse()
        } else if let button = statusItem?.button, let anchor = trigger(from: button, physicalClick: false) {
            show(level, from: anchor)
        } else {
            message = L10n.text("找不到菜单栏箭头。请确认菜单栏有足够的空间，然后重试。")
        }
        onChange?()
    }

    private func save(_ next: Settings) -> Bool {
        do {
            try store.save(next)
            settings = next
            return true
        } catch {
            message = L10n.text("无法保存菜单栏设置。%@", error.localizedDescription)
            onChange?()
            return false
        }
    }

    func refresh(retry: Bool = false) {
        if retry { failed = false; message = nil }
        guard enabled || watchInventory else { return }
        guard trusted else {
            hasScan = false
            apps = []
            if expansion != .collapsed { collapse() }
            releaseAssertion()
            if !needsPermissionNotice {
                needsPermissionNotice = true
                onChange?()
            }
            return
        }
        needsPermissionNotice = false
        guard scan == nil else { pendingRescan = pendingRescan || retry; return }
        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications.filter { !$0.isTerminated }
        let byPID = Dictionary(uniqueKeysWithValues: running.map { ($0.processIdentifier, $0) })
        let agent = running.first { $0.bundleIdentifier == "com.apple.MenuBarAgent" }?.processIdentifier
        scan = Task { [weak self] in
            let result = await MenuBarInventory.read(pids: Array(byPID.keys).filter { $0 != getpid() }, agent: agent)
            guard let self, !Task.isCancelled else { return }
            self.scan = nil
            guard self.trusted else { self.refresh(); return }
            self.accept(result, running: byPID)
            if self.pendingRescan {
                self.pendingRescan = false
                self.refresh()
            }
        }
        onChange?()
    }

    private func accept(_ result: MenuBarInventory.Result, running: [pid_t: NSRunningApplication]) {
        guard enabled || watchInventory else { return }
        runningIDs = Set(running.values.compactMap(\.bundleIdentifier))
        let previous = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        var found: [String: MenuBarApp] = [:]
        let agentExtras = Dictionary(grouping: result.agentItems, by: \.pid)
        for (pid, app) in running {
            guard let id = app.bundleIdentifier, id != appID else { continue }
            let system = id.hasPrefix("com.apple.")
            let direct = result.extras[pid] ?? []
            let managed = distinctAgentItems(agentExtras[pid] ?? [])
            // MenuBarAgent exposes a copy of the item on each display. Prefer
            // the app's own AX tree to determine how many distinct items it owns.
            let reported = direct.count >= managed.count ? direct : managed
            let priorExtras = previous[id]?.extras.filter { $0.pid == pid } ?? []
            let extras = reported.isEmpty && settings.rules[id] != nil && assertion != nil ? priorExtras : reported
            guard !extras.isEmpty else { continue }
            if var existing = found[id] {
                existing.extras.append(contentsOf: extras)
                found[id] = existing
            } else {
                found[id] = inventoryApp(app, id: id, system: system, extras: extras)
            }
        }
        apps = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        hasScan = true
        nativeLeft = nativeLeft.filter { runningIDs.contains($0.key) }
        rememberNativeOrder(result.agentItems)
        if expansion != .collapsed, !arranging,
           Set(apps.filter(\.canMove).map(\.id)) != Set(previous.values.filter(\.canMove).map(\.id)) {
            collapse()
        }
        reconcile()
        onChange?()
    }

    private func inventoryApp(_ app: NSRunningApplication, id: String, system: Bool, extras: [MenuBarExtra]) -> MenuBarApp {
        if id == MenuBarApp.inputMenuID {
            let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
            let sourceID = source.flatMap { TISGetInputSourceProperty($0, kTISPropertyInputSourceID) }
                .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
            let iconURL = source.flatMap { TISGetInputSourceProperty($0, kTISPropertyIconImageURL) }
                .map { Unmanaged<CFURL>.fromOpaque($0).takeUnretainedValue() as URL }
            let icon = iconURL.flatMap(NSImage.init(contentsOf:))
            if sourceID?.hasPrefix(MenuBarApp.sogouID + ".") == true { icon?.isTemplate = true }
            let keyboard = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
            return MenuBarApp(id: id, name: L10n.text("输入法切换菜单"), icon: icon ?? keyboard,
                              iconSource: sourceID, system: system, extras: extras)
        }
        if id == MenuBarApp.sogouID {
            let bundle = app.bundleURL.flatMap(Bundle.init(url:))
            let smile = MenuBarArtwork.sogouGlyph("icon_picface", in: bundle, fallback: "face.smiling")
            return MenuBarApp(id: id, name: L10n.text("搜狗拼音（笑脸和中英切换）"), icon: smile, system: system, extras: extras)
        }
        let workspace = NSWorkspace.shared
        // Docker Desktop's nested Electron app owns the menu item. Use the installed Docker app's artwork.
        let iconURL = id == "com.electron.dockerdesktop"
            ? workspace.urlForApplication(withBundleIdentifier: "com.docker.docker")
            : nil
        let icon = iconURL.map { workspace.icon(forFile: $0.path) } ?? app.icon
        return MenuBarApp(id: id, name: app.localizedName ?? id, icon: icon,
                          iconSource: iconURL?.path, system: system, extras: extras)
    }

    private func distinctAgentItems(_ items: [MenuBarExtra]) -> [MenuBarExtra] {
        // The same item's AX element can appear in several MenuBarAgent
        // windows. Use one display, retaining even items with equal labels.
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return CGDisplayBounds(id)
        }
        let copies = displays.map { bounds in items.filter { Self.isOnMenuBar($0.frame, in: bounds) } }
        return copies.max(by: { $0.count < $1.count }) ?? []
    }

    private static func isOnMenuBar(_ item: CGRect, in display: CGRect) -> Bool {
        display.minX <= item.midX && item.midX < display.maxX && abs(item.minY - display.minY) < 10
    }

    private func rememberNativeOrder(_ items: [MenuBarExtra]) {
        for screen in NSScreen.screens {
            guard let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let onScreen = items.filter { Self.isOnMenuBar($0.frame, in: CGDisplayBounds(display)) }
            guard let arrow = onScreen.first(where: {
                $0.pid == getpid() && ($0.label == Self.expandLabel || $0.label == Self.collapseLabel)
            }) else { continue }

            let byOwner = Dictionary(grouping: onScreen, by: \.pid)
            for app in apps where app.canMove {
                let pids = Set(app.extras.map(\.pid))
                let observed = pids.flatMap { byOwner[$0] ?? [] }
                if observed.contains(where: { $0.frame.minX >= arrow.frame.minX }) {
                    nativeLeft[app.id] = false
                } else if observed.count >= app.extras.count {
                    nativeLeft[app.id] = true
                }
            }
        }
    }

    private var desiredConfiguration: VisibilityConfiguration? {
        guard enabled, canHide, trusted, hasScan, !failed else { return nil }
        let hidden = apps.filter { $0.canMove && !nativeExpansion.shows(rule($0)) }
        guard !hidden.isEmpty else { return nil }
        let allowed = runningIDs.subtracting(hidden.map(\.id))
            .union([appID, "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"])
        return VisibilityConfiguration(apps: allowed.sorted(), showsInputMenu: !hidden.contains(where: \.isInputMenu))
    }

    private func reconcile() {
        let desired = desiredConfiguration
        guard let desired else { releaseAssertion(); return }
        guard !applying, currentConfiguration != desired else { return }
        applying = true
        onChange?()
        NookletMenuBarRestrict(desired.apps, desired.showsInputMenu) { [weak self] new, error in
            // The bridge completes on main, including immediate failures.
            MainActor.assumeIsolated {
                guard let self else { if let new { NookletMenuBarRelease(new) }; return }
                self.applying = false
                defer { self.onChange?() }
                guard self.desiredConfiguration == desired else {
                    if let new { NookletMenuBarRelease(new) }
                    self.reconcile()
                    return
                }
                guard let new else {
                    self.failed = true
                    self.releaseAssertion()
                    self.message = L10n.text("无法隐藏菜单栏图标。%@", error?.localizedDescription ?? "")
                    return
                }
                let old = self.assertion
                self.assertion = new
                self.currentConfiguration = desired
                if let old { NookletMenuBarRelease(old) }
            }
        }
    }

    private func releaseAssertion() {
        if let assertion { NookletMenuBarRelease(assertion) }
        assertion = nil
        currentConfiguration = nil
    }

    private func updateTimer() {
        if enabled || watchInventory {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer?.tolerance = 1
        } else {
            timer?.invalidate()
            timer = nil
            scan?.cancel()
            scan = nil
        }
    }

    private func installButton() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Nooklet.MenuBar.Expand"
        if let button = item.button {
            button.target = self
            button.action = #selector(handleStatusClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(Self.expandLabel)
        }
        statusItem = item
        updateButton()
    }

    private func removeButton() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func handleStatusClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            lastArrowClick = nil
            let menu = NSMenu()
            let all = NSMenuItem(title: Self.showAllTitle, action: #selector(openAll), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
            let arrange = NSMenuItem(title: L10n.text("整理原生图标…"), action: #selector(openArrangement), keyEquivalent: "")
            arrange.target = self
            menu.addItem(arrange)
            let item = NSMenuItem(title: L10n.text("菜单栏图标设置…"), action: #selector(openSettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            contextTrigger = trigger(from: sender, physicalClick: true)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
            contextTrigger = nil
            return
        }
        let click = event?.type == .leftMouseUp ? event : nil
        guard click?.modifierFlags.contains(.command) != true else { return }
        guard let trigger = trigger(from: sender, physicalClick: click != nil) else { return }
        let display = trigger.screen.frame
        let adjacentClick = click.flatMap { current in
            lastArrowClick.map {
                $0.display == display && (0...NSEvent.doubleClickInterval).contains(current.timestamp - $0.time)
            }
        } ?? false
        if click?.clickCount == 2 || adjacentClick {
            lastArrowClick = nil
            show(.all, from: trigger)
        } else if (click?.clickCount ?? 1) <= 1 {
            if expansion == .collapsed { show(.hidden, from: trigger) }
            else { collapse() }
            lastArrowClick = click.map { ($0.timestamp, display) }
        }
    }

    @objc private func openSettings() { collapse(); onSettings?() }
    @objc private func openAll() {
        show(.all, from: contextTrigger)
    }

    @objc private func openArrangement() {
        guard trusted, canHide, hasScan, !failed, let trigger = contextTrigger else { return }
        beginArrangement(from: trigger)
    }

    private func trigger(from button: NSStatusBarButton, physicalClick: Bool) -> ExpansionTrigger? {
        guard let window = button.window else { return nil }
        let pointer = NSEvent.mouseLocation
        let clickedScreen = physicalClick ? NSScreen.screens.first {
            $0.frame.contains(pointer) && $0.frame.maxY - pointer.y <= max($0.safeAreaInsets.top, NSStatusBar.system.thickness) + 3
        } : nil
        guard let screen = clickedScreen ?? window.screen ?? NSScreen.main else { return nil }
        let original = window.convertToScreen(button.convert(button.bounds, to: nil))
        let anchor = anchorFrame(original, on: screen, pointer: physicalClick ? pointer : nil)
        return ExpansionTrigger(anchor: anchor, screen: screen)
    }

    private func show(_ level: MenuBarExpansion, from trigger: ExpansionTrigger?) {
        guard trusted, canHide, hasScan, !failed else { openSettings(); return }
        guard let trigger else { return }
        let target = editableApps.filter { rule($0) != .visible && level.shows(rule($0)) }
        guard !target.isEmpty else { collapse(); return }

        expansionTask?.cancel()
        arrangementPanel?.close()
        arrangementPanel = nil
        arranging = false
        expansion = level
        let arranged = target.allSatisfy { nativeLeft[$0.id] == true }
        nativeExpansion = arranged ? level : .collapsed
        reconcile()
        updateButton()
        if !arranged { offerArrangement(from: trigger, then: level) }
    }

    private func offerArrangement(from trigger: ExpansionTrigger, then level: MenuBarExpansion) {
        let guide = MenuBarArrangementPanel()
        guide.onClose = { [weak self] in self?.collapse() }
        guide.show(title: L10n.text("整理原生菜单栏图标"),
                        detail: L10n.text("将隐藏的图标排在箭头左侧，就能直接在那里展开和使用原生图标。"),
                        action: L10n.text("开始整理"), anchor: trigger.anchor, screen: trigger.screen) { [weak self] in
            self?.beginArrangement(from: trigger, then: level)
        }
        arrangementPanel = guide
    }

    private func beginArrangement(from trigger: ExpansionTrigger, then level: MenuBarExpansion = .collapsed) {
        expansionTask?.cancel()
        arranging = true
        expansion = .all
        nativeExpansion = .all
        reconcile()
        updateButton()
        showArrangementGuide(from: trigger, then: level)
    }

    private func showArrangementGuide(from trigger: ExpansionTrigger, then level: MenuBarExpansion, remaining: Int? = nil) {
        arrangementPanel?.close()
        let guide = MenuBarArrangementPanel()
        guide.onClose = { [weak self] in self?.collapse() }
        let instruction = L10n.text("按住 ⌘，把要隐藏的图标拖到箭头左侧，或把箭头拖到这些图标的右侧。空间不足时，可在较宽的屏幕上整理。")
        let detail = remaining.map { L10n.text("还有 %@ 个应用的图标需要整理。 ", $0) + instruction } ?? instruction
        guide.show(title: L10n.text("整理原生菜单栏图标"), detail: detail, action: L10n.text("完成"),
                        anchor: trigger.anchor, screen: trigger.screen) { [weak self] in
            self?.finishArrangement(from: trigger, then: level)
        }
        arrangementPanel = guide
    }

    private func finishArrangement(from trigger: ExpansionTrigger, then level: MenuBarExpansion) {
        expansionTask?.cancel()
        expansionTask = Task { [weak self] in
            guard let self, self.arranging,
                  let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return }
            let items = await MenuBarInventory.readAgentItems(agent.processIdentifier)
            guard !Task.isCancelled, self.arranging else { return }
            self.rememberNativeOrder(items)
            let remaining = self.editableApps.filter { self.rule($0) != .visible && self.nativeLeft[$0.id] != true }.count
            if remaining > 0 {
                self.showArrangementGuide(from: trigger, then: level, remaining: remaining)
            } else if level == .collapsed {
                self.collapse()
            } else {
                self.show(level, from: trigger)
            }
        }
    }

    private func anchorFrame(_ rect: CGRect, on screen: NSScreen, pointer: CGPoint?) -> CGRect {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if screen.frame.contains(center), pointer.map({ rect.insetBy(dx: -8, dy: -5).contains($0) }) ?? true {
            return rect
        }
        let height = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        return CGRect(x: (pointer?.x ?? rect.midX) - rect.width / 2, y: screen.frame.maxY - height,
                      width: rect.width, height: height)
    }

    private func updateButton() {
        let symbol = expansion == .collapsed ? "chevron.left" : "chevron.down"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusItem?.button?.setAccessibilityLabel(expansion == .collapsed ? Self.expandLabel : Self.collapseLabel)
        statusItem?.button?.toolTip = L10n.text("单击展开或收起 · 双击或右键展开全部（含始终隐藏）")
    }

    func screenConfigurationChanged() {
        collapse()
        refresh()
    }

    private func collapse() {
        lastArrowClick = nil
        expansionTask?.cancel()
        expansionTask = nil
        arrangementPanel?.close()
        arrangementPanel = nil
        expansion = .collapsed
        nativeExpansion = .collapsed
        arranging = false
        reconcile()
        updateButton()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scan?.cancel()
        scan = nil
        failed = true
        collapse()
        releaseAssertion()
        removeButton()
    }
}
