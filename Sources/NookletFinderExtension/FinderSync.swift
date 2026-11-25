@preconcurrency import AppKit
import FinderSync
import NookletCore
import OSLog

final class FinderSync: FIFinderSync {
    private enum Command {
        case request(FinderRequest)
        case copy(FinderAction, [URL])
    }

    private let controller = FIFinderSyncController.default()
    private static let logger = Logger(subsystem: "dev.local.Nooklet", category: "FinderTools")
    private var commands: [Int: Command] = [:]
    private var nextTag = 0

    override init() {
        super.init()
        NookletLocalization.configure(.system)
        updateDirectories()
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateDirectories),
                                                               name: name, object: nil)
        }
    }

    @objc private func updateDirectories() {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: .skipHiddenVolumes) ?? []
        controller.directoryURLs = Set(volumes + [URL(fileURLWithPath: "/", isDirectory: true)])
    }

    override func menu(for kind: FIMenuKind) -> NSMenu? {
        commands.removeAll(keepingCapacity: true)
        guard kind != .toolbarItemMenu, let target = controller.targetedURL(), target.isFileURL else { return nil }

        let settings: FinderToolsSettings
        do {
            settings = try FinderToolsSettings.store.load() ?? FinderToolsSettings()
        } catch {
            Self.logger.error("Could not load Finder menu settings: \(error.localizedDescription, privacy: .private)")
            return nil
        }

        // Finder may still have selected items when the window background is clicked.
        let isBackground = kind == .contextualMenuForContainer
        let selected = kind == .contextualMenuForItems ? controller.selectedItemURLs()?.filter(\.isFileURL) ?? [] : []
        let urls = selected.contains(target) ? selected : [target]
        let menu = NSMenu()
        menu.autoenablesItems = false

        if urls.count == 1 {
            let targetIsFolder = isBackground || isFolder(target)
            let directory = targetIsFolder ? target : target.deletingLastPathComponent()
            if settings.enabled.contains(.newFolder) {
                menu.addItem(item(FinderAction.newFolder.title, command: .request(.newFolder(directory))))
            }
            if settings.enabled.contains(.newFile) {
                let formats = FinderNewFile.allCases.map { item(".\($0.rawValue)", command: .request(.newFile($0, directory))) }
                addSubmenu(FinderAction.newFile.title, items: formats, to: menu)
            }
            if settings.enabled.contains(.openTerminal) {
                menu.addItem(item(FinderAction.openTerminal.title, command: .request(.openTerminal(directory))))
            }
        }

        let copyActions: [FinderAction] = [.copyName, .copyAbsolutePath, .copyRelativePath, .copyEscapedPath, .copyFileURL]
        for action in copyActions where settings.enabled.contains(action) && (!isBackground || action != .copyName) {
            menu.addItem(item(action.title, command: .copy(action, urls)))
        }
        if settings.enabled.contains(.openWith), !settings.applications.isEmpty {
            let apps = settings.applications.map { item($0.name, command: .request(.openWith($0, urls))) }
            addSubmenu(FinderAction.openWith.title, items: apps, to: menu)
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (values?.isDirectory ?? url.hasDirectoryPath) && values?.isPackage != true
    }

    private func item(_ title: String, command: Command) -> NSMenuItem {
        nextTag += 1
        commands[nextTag] = command
        let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: "")
        item.tag = nextTag
        item.target = self
        return item
    }

    private func addSubmenu(_ title: String, items: [NSMenuItem], to menu: NSMenu) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        submenu.items = items
        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func performCommand(_ item: NSMenuItem) {
        guard let command = commands[item.tag] else { return }
        do {
            switch command {
            case .request(let request):
                try send(request)
            case .copy(let action, let urls):
                if let text = action.clipboardText(for: urls, relativeTo: FinderToolsSettings.userHome) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        } catch {
            Task { @MainActor in Self.showError(error) }
        }
    }

    private func send(_ command: FinderRequest) throws {
        // The Finder Sync sandbox can identify selected items. The host performs file operations.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let request = try command.write()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.open([request], withApplicationAt: app, configuration: configuration) { _, error in
            guard let error else { return }
            try? FileManager.default.removeItem(at: request)
            Task { @MainActor in Self.showError(error) }
        }
    }

    @MainActor private static func showError(_ error: Error) {
        let underlying = error as NSError
        logger.error("Finder command failed: \(underlying.domain, privacy: .public) code \(underlying.code, privacy: .public)")
        NSApp.activate()
        NSAlert(error: error).runModal()
    }
}
