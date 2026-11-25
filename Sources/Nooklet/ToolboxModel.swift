import AppKit
import Combine
import NookletCore

typealias L10n = NookletLocalization

extension PluginTemplate {
    fileprivate var isBundledOnly: Bool {
        switch self {
        case .diskEject, .homebrew, .runningApps, .zshConfiguration: true
        default: false
        }
    }

    var isEnabledInToolbox: Bool {
        switch self {
        case .island, .cooling, .appDiagnostics: false
        default: true
        }
    }
}

extension StatusMetric {
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .network: L10n.text("网络")
        case .processes: L10n.text("进程")
        case .memory: L10n.text("内存")
        case .disk: L10n.text("磁盘")
        case .battery: L10n.text("电池")
        case .thermal: L10n.text("热状态")
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "display"
        case .network: "wifi"
        case .processes: "list.bullet.rectangle"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        case .thermal: "thermometer.medium"
        }
    }

    var color: NSColor {
        switch self {
        case .cpu: ToolboxAppearance.green
        case .gpu: ToolboxAppearance.orange
        case .network: .systemCyan
        case .memory: ToolboxAppearance.amber
        case .disk: ToolboxAppearance.blue
        case .battery: .systemTeal
        case .processes: .secondaryLabelColor
        case .thermal: .systemRed
        }
    }
}

@MainActor
final class ToolboxModel: ObservableObject {
    let paths: AppPaths
    lazy var menuBar = MenuBarController(paths: paths)
    lazy var storageBrowser = StorageBrowser()
    lazy var lanShare = LANShareController(paths: paths)
    let disks: DiskEjectModel
    let homebrew: HomebrewModel
    let zsh: ZshConfigurationModel
    let softwareUpdate = SoftwareUpdateModel()
    private let registry: PluginRegistry
    private let store: LocalJSONStore<DisplayPreferences>
    private let generalStore: LocalJSONStore<GeneralPreferences>
    private(set) var plugins: [PluginManifest] = []
    @Published private(set) var preferences = DisplayPreferences()
    @Published private(set) var general: GeneralPreferences
    var onChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(paths: AppPaths) throws {
        self.paths = paths
        try paths.ensureDirectories()
        registry = PluginRegistry(paths: paths)
        store = LocalJSONStore(url: paths.rootDirectory.appendingPathComponent("display.json"))
        let generalStore = LocalJSONStore<GeneralPreferences>(url: paths.generalPreferencesURL)
        self.generalStore = generalStore
        let general = try generalStore.load() ?? GeneralPreferences()
        self.general = general
        L10n.configure(general.language)
        disks = DiskEjectModel()
        homebrew = HomebrewModel()
        zsh = ZshConfigurationModel()
    }

    func updateGeneral(_ edit: (inout GeneralPreferences) -> Void) {
        var updated = general
        edit(&updated)
        guard updated != general else { return }
        do {
            try generalStore.save(updated)
            let appearanceChanged = updated.theme != general.theme || updated.customColor != general.customColor
            general = updated
            if appearanceChanged { onAppearanceChange?() }
        } catch {
            onError?(error)
        }
    }

    func restore() throws {
        preferences = try store.load() ?? DisplayPreferences()
        plugins = try registry.installedPlugins().filter { $0.kind != .countdown }
        let packaged = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("Nooklet_Nooklet.bundle"))
        }
        guard let directory = (packaged ?? .module).url(forResource: "BundledPlugins", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        for source in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where source.pathExtension == "plugin" {
            let manifest = try registry.manifest(from: source)
            if manifest.kind != .countdown, !plugins.contains(where: { $0.id == manifest.id }) {
                // Tools tied to this build stay in the bundle so an older build can still read the user's plugins.
                if manifest.kind?.isBundledOnly == true {
                    plugins.append(manifest)
                } else {
                    plugins.append(try registry.importPlugin(from: source))
                }
            }
        }
        plugins.sort { $0.id < $1.id }
    }

    func updateDisplay(_ edit: (inout DisplayPreferences) -> Void) {
        var updated = preferences
        edit(&updated)
        guard updated != preferences else { return }
        do {
            try store.save(updated)
            preferences = updated
            onChange?()
        } catch {
            onError?(error)
            onChange?()
        }
    }

    func importPlugin(from url: URL) throws -> PluginManifest {
        switch try registry.manifest(from: url).kind {
        case .countdown:
            throw PluginError.invalidManifest(L10n.text("专注计时已从 Nooklet 移除。"))
        case .some(let kind) where kind.isBundledOnly:
            throw PluginError.invalidManifest(L10n.text("此工具已经随 Nooklet 提供。"))
        default: break
        }
        let manifest = try registry.importPlugin(from: url)
        plugins.removeAll { $0.id == manifest.id }
        plugins.append(manifest)
        plugins.sort { $0.id < $1.id }
        onChange?()
        return manifest
    }
}
