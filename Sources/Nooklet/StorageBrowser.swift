import AppKit
import Combine
import NookletCore

@MainActor
final class StorageBrowser: ObservableObject {
    private struct Location {
        let url: URL
        let item: StorageItem?

        init(_ url: URL, item: StorageItem? = nil) {
            self.url = url
            self.item = item
        }
    }

    @Published private(set) var directory: URL?
    @Published private(set) var root: URL?
    @Published private(set) var result: StorageScan?
    @Published private(set) var selection: URL?
    @Published private(set) var queued: [StorageItem] = []
    @Published private(set) var scanMessage: String?
    @Published private(set) var cleanupMessage: String?
    @Published private(set) var isScanning = false
    @Published private(set) var isTrashing = false
    @Published var trashError: String?

    private var history: [Location] = []
    private var cursor = 0
    private var cache: [StorageScan] = []
    private var scanTask: Task<StorageScan, Error>?
    private var scanID: UUID?
    private var attached = false
    private var needsRefresh = false

    var canBack: Bool { cursor > 0 }
    var canForward: Bool { cursor + 1 < history.count }

    func attach() {
        attached = true
        if needsRefresh { reload() }
    }

    func detach() {
        attached = false
        cancel()
    }

    func choose(_ url: URL) {
        guard !isTrashing else { return }
        let directory = url.resolvingSymlinksInPath()
        if directory.path == root?.path {
            if self.directory?.path == directory.path { reload() }
            else { visit(Location(directory)) }
            return
        }
        root = directory
        history = [Location(directory)]
        cursor = 0
        cache.removeAll()
        queued.removeAll()
        cleanupMessage = nil
        load(history[0])
    }

    func open(_ item: StorageItem) {
        guard !isTrashing else { return }
        if item.isDirectory {
            visit(Location(item.url, item: item))
        } else {
            selection = item.url
        }
    }

    func visitAncestor(_ url: URL) {
        guard let directory, let root, StorageScanner.isWithin(url, directory: root),
              StorageScanner.isWithin(directory, directory: url) else { return }
        visit(history.last { $0.url.path == url.path } ?? Location(url))
    }

    func back() {
        guard canBack, !isTrashing else { return }
        cursor -= 1
        load(history[cursor])
    }

    func forward() {
        guard canForward, !isTrashing else { return }
        cursor += 1
        load(history[cursor])
    }

    func reload() {
        guard !history.isEmpty, !isTrashing else { return }
        cache.removeAll()
        load(history[cursor])
    }

    func cancel() {
        guard let scanTask else { return }
        scanTask.cancel()
        self.scanTask = nil
        scanID = nil
        isScanning = false
        scanMessage = L10n.text("分析已取消")
    }

    func reveal(_ item: StorageItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func isCovered(_ item: StorageItem) -> Bool {
        queued.contains { $0.isDirectory && StorageScanner.isWithin(item.url, directory: $0.url, includingDirectory: false) }
    }

    func isQueued(_ item: StorageItem) -> Bool { queued.contains { $0.url == item.url } }

    @discardableResult
    func addToQueue(_ item: StorageItem) -> Bool {
        guard !isTrashing, item.canTrash, let root, StorageScanner.isWithin(item.url, directory: root, includingDirectory: false),
              !isCovered(item), !isQueued(item) else { return false }
        if item.isDirectory { queued.removeAll { StorageScanner.isWithin($0.url, directory: item.url) } }
        queued.append(item)
        cleanupMessage = nil
        return true
    }

    func removeFromQueue(_ url: URL) {
        if !isTrashing { queued.removeAll { $0.url == url } }
    }

    func clearQueue() {
        if !isTrashing { queued.removeAll() }
    }

    func trash(_ items: [StorageItem]) {
        guard !isTrashing, let root, !items.isEmpty else { return }
        cancel()
        isTrashing = true
        cleanupMessage = nil
        let worker = Task.detached(priority: .utility) {
            var moved: [StorageItem] = []
            var errors: [String] = []
            for item in items {
                do {
                    try StorageScanner.validateForTrash(item, in: root)
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                    moved.append(item)
                } catch {
                    errors.append("\(item.url.lastPathComponent) · \(error.localizedDescription)")
                }
            }
            return (moved, errors)
        }
        Task {
            let (moved, errors) = await worker.value
            finishTrash(moved: moved, errors: errors)
        }
    }

    private func visit(_ location: Location) {
        guard !isTrashing, let root, StorageScanner.isWithin(location.url, directory: root) else { return }
        if directory?.path == location.url.path {
            if result == nil, !isScanning { reload() }
            return
        }
        history = Array(history.prefix(cursor + 1))
        history.append(location)
        cursor = history.count - 1
        load(location)
    }

    private func load(_ location: Location) {
        cancel()
        directory = location.url
        selection = nil
        scanMessage = nil
        needsRefresh = false
        if let index = cache.firstIndex(where: { $0.directory.path == location.url.path }) {
            let hit = cache.remove(at: index)
            cache.append(hit)
            result = hit
            return
        }

        result = nil
        isScanning = true
        let id = UUID()
        scanID = id
        let worker = Task.detached(priority: .utility) {
            if let item = location.item { return try StorageScanner.scan(item) }
            guard location.url.resolvingSymlinksInPath().path == location.url.path else { throw StorageScanError.itemChanged }
            return try StorageScanner.scan(location.url)
        }
        scanTask = worker
        Task { [weak self] in
            let outcome = await worker.result
            guard let self, scanID == id else { return }
            scanTask = nil
            scanID = nil
            isScanning = false
            switch outcome {
            case .success(let scan):
                if cache.count == 4 { cache.removeFirst() }
                cache.append(scan)
                result = scan
            case .failure(let error):
                scanMessage = error.localizedDescription
            }
        }
    }

    private func finishTrash(moved: [StorageItem], errors: [String]) {
        isTrashing = false
        func wasRemoved(_ url: URL) -> Bool {
            moved.contains { StorageScanner.isWithin(url, directory: $0.url) }
        }
        queued.removeAll { wasRemoved($0.url) }
        cleanupMessage = moved.isEmpty ? nil : L10n.text("已将 %@ 项移到废纸篓", moved.count)
        if !errors.isEmpty { trashError = errors.joined(separator: "\n") }

        let location = history[cursor]
        cache.removeAll()
        if let folder = moved.first(where: { StorageScanner.isWithin(location.url, directory: $0.url) }) {
            let parent = folder.url.deletingLastPathComponent()
            history.removeAll { wasRemoved($0.url) }
            if let index = history.lastIndex(where: { $0.url.path == parent.path }) {
                cursor = index
            } else {
                history.append(Location(parent))
                cursor = history.count - 1
            }
        } else {
            let removedBefore = history.prefix(cursor).filter { wasRemoved($0.url) }.count
            history.removeAll { wasRemoved($0.url) }
            cursor -= removedBefore
        }

        if attached {
            load(history[cursor])
        } else {
            result = nil
            directory = history[cursor].url
            needsRefresh = true
        }
    }
}
