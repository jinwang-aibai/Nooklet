import Foundation
import NookletCore

@MainActor
final class LANShareController {
    private let store: LocalJSONStore<LANShareSettings>
    private var service: LANShare?
    private var session: UUID?
    private(set) var settings = LANShareSettings()
    private(set) var link: URL?
    private(set) var address: String?
    private(set) var connectionError: String?
    private(set) var contentError: String?
    private(set) var unavailable = Set<UUID>()
    var draft = ""
    var onChange: (() -> Void)?

    var isRunning: Bool { service != nil }

    init(paths: AppPaths) {
        store = LocalJSONStore(url: paths.rootDirectory.appendingPathComponent("lan-share.json"), maximumBytes: 8_388_608)
        do {
            settings = try store.load() ?? LANShareSettings()
            draft = settings.text
        } catch {
            contentError = error.localizedDescription
        }
    }

    @discardableResult
    func add(_ urls: [URL]) -> Bool {
        var next = settings
        var paths = Set(settings.entries.map { $0.url.standardizedFileURL.path })
        var rejected = 0
        for url in urls {
            guard !paths.contains(url.standardizedFileURL.path) else { continue }
            guard let entry = try? LANShareEntry(url: url) else { rejected += 1; continue }
            paths.insert(entry.url.path)
            next.entries.append(entry)
        }
        let added = next.entries.count - settings.entries.count
        if rejected > 0 {
            contentError = added > 0 ? L10n.text("已添加 %@ 项；另外 %@ 项无法读取。", added, rejected) : L10n.text("无法读取所选项目。请选择本机文件或文件夹。")
        } else {
            contentError = added == 0 ? L10n.text("所选项目已在共享目录中。") : nil
        }
        guard next != settings else { onChange?(); return false }
        return save(next)
    }

    func remove(_ id: UUID) {
        var next = settings
        next.entries.removeAll { $0.id == id }
        contentError = nil
        save(next)
    }

    func publishText() {
        var next = settings
        next.text = draft
        contentError = nil
        save(next)
    }

    @discardableResult
    private func save(_ next: LANShareSettings) -> Bool {
        do {
            try store.save(next)
        } catch {
            contentError = L10n.text("无法保存共享内容：%@", error.localizedDescription)
            onChange?()
            return false
        }
        if next.entries != settings.entries {
            unavailable = service?.setEntries(next.entries) ?? unavailable.intersection(next.entries.map(\.id))
        }
        if next.text != settings.text { service?.setText(next.text) }
        settings = next
        onChange?()
        return true
    }

    func start(address: String) {
        guard !isRunning else { return }
        let id = UUID()
        connectionError = nil
        do {
            service = try LANShare(address: address) { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self, self.session == id else { return }
                    switch event {
                    case .ready(let url):
                        self.link = url
                    case .ended(let message):
                        self.service = nil
                        self.session = nil
                        self.link = nil
                        self.address = nil
                        self.connectionError = message
                    }
                    self.onChange?()
                }
            }
            self.address = address
            session = id
            unavailable = service?.setEntries(settings.entries) ?? []
            service?.setText(settings.text)
        } catch {
            connectionError = error.localizedDescription
        }
        onChange?()
    }

    func stop() {
        service?.stop()
        service = nil
        session = nil
        link = nil
        address = nil
        connectionError = nil
        onChange?()
    }
}
