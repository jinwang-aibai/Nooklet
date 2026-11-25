import AppKit
import NookletCore
import SwiftUI

@MainActor
final class StoragePanel: ToolPanel {
    private let browser: StorageBrowser

    init(heading: String, browser: StorageBrowser) {
        self.browser = browser
        super.init(heading: heading, detail: L10n.text("面积代表已分配的磁盘空间。点击文件夹可查看内部占用。"))
    }

    required init?(coder: NSCoder) { nil }

    override func makeBody() -> NSView {
        browser.attach()
        let hosting = NSHostingView(rootView: StorageAnalysisView(browser: browser))
        hosting.sizingOptions = []
        return hosting
    }

    override func endUse() { browser.detach() }
}

@MainActor
private struct StorageAnalysisView: View {
    private struct Review: Identifiable {
        let id = UUID()
        let items: [StorageItem]
    }

    @ObservedObject var browser: StorageBrowser
    @State private var review: Review?

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 10) {
                toolbar
                if let directory = browser.directory {
                    breadcrumb(directory)
                    if let result = browser.result {
                        statistics(result)
                        results(result)
                    } else {
                        unavailable
                    }
                    reviewBar
                } else {
                    placeholder(L10n.text("选择文件夹或分析个人目录"), image: "internaldrive")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .sheet(item: $review) { review in
            StorageReviewSheet(items: review.items, root: browser.root) {
                self.review = nil
            } onTrash: {
                self.review = nil
                browser.trash(review.items)
            }
        }
        .alert(L10n.text("有项目未能移到废纸篓"), isPresented: Binding(
            get: { browser.trashError != nil },
            set: { if !$0 { browser.trashError = nil } }
        )) {
            Button(L10n.text("好")) { browser.trashError = nil }
        } message: {
            Text(browser.trashError ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 7) {
            HStack(spacing: 4) {
                toolbarButton(L10n.text("后退"), symbol: "chevron.left", enabled: browser.canBack, action: browser.back)
                toolbarButton(L10n.text("前进"), symbol: "chevron.right", enabled: browser.canForward, action: browser.forward)
            }
            Spacer(minLength: 0)
            Button(L10n.text("分析个人目录"), systemImage: "house") {
                browser.choose(FileManager.default.homeDirectoryForCurrentUser)
            }
            Button(L10n.text("选择文件夹…"), systemImage: "folder", action: chooseFolder).buttonStyle(.borderedProminent)
            if browser.isScanning {
                Button(L10n.text("取消分析"), action: browser.cancel)
            } else {
                toolbarButton(L10n.text("重新分析"), symbol: "arrow.clockwise", enabled: browser.directory != nil, action: browser.reload)
            }
        }
        .disabled(browser.isTrashing)
    }

    private func toolbarButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 14) }
            .help(title)
            .accessibilityLabel(title)
            .disabled(!enabled)
    }

    private func breadcrumb(_ directory: URL) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(ancestors(directory), id: \.path) { part in
                        if part.path != browser.root?.path {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                        if part.path == directory.path {
                            Text(storageName(part))
                                .fontWeight(.semibold)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 7)
                                .background(Color(nsColor: ToolboxAppearance.selection), in: RoundedRectangle(cornerRadius: 5))
                                .id(part.path)
                        } else {
                            Button(storageName(part)) { browser.visitAncestor(part) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(directory.path, anchor: .trailing) }
            .onChange(of: directory) { _, value in proxy.scrollTo(value.path, anchor: .trailing) }
            .help(directory.path)
            .disabled(browser.isTrashing)
        }
    }

    private func ancestors(_ directory: URL) -> [URL] {
        var path = [directory]
        guard let root = browser.root else { return path }
        var parent = directory
        while parent.path != root.path {
            let next = parent.deletingLastPathComponent()
            guard next.path != parent.path, StorageScanner.isWithin(next, directory: root) else { break }
            path.append(next)
            parent = next
        }
        return path.reversed()
    }

    private func statistics(_ scan: StorageScan) -> some View {
        let visible = scan.itemCount > scan.items.count ? L10n.text(" · 列表显示前 %@ 项", scan.items.count) : ""
        let partial = scan.skippedCount > 0 ? L10n.text(" · 跳过 %@ 项", scan.skippedCount) : ""
        return HStack(spacing: 8) {
            Text(storageSize(scan.totalBytes)).font(.subheadline.weight(.semibold).monospacedDigit())
            Text(L10n.text("%@ 个文件 · %@ 个直接项目%@%@", scan.fileCount, scan.itemCount, visible, partial))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(L10n.text("按实际分配空间统计，跳过链接、跨卷项目和无法访问的内容。"))
    }

    private func results(_ scan: StorageScan) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 9) {
                StorageTreemapView(scan: scan, browser: browser, onReview: reviewItem)
                    .frame(width: max(0, (geometry.size.width - 9) * 0.56))
                rankedList(scan.items)
            }
        }
        .frame(minHeight: 135)
        .disabled(browser.isTrashing)
    }

    private func rankedList(_ items: [StorageItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("项目"))
                Spacer()
                Text(L10n.text("占用空间"))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            if items.isEmpty {
                placeholder(L10n.text("此文件夹没有可列出的项目"), image: "folder")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 9) }
                            resultRow(item, index: index)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary) }
    }

    private func resultRow(_ item: StorageItem, index: Int) -> some View {
        HStack(spacing: 5) {
            StorageQueueButton(item: item, browser: browser)
            Button { browser.open(item) } label: {
                HStack(spacing: 6) {
                    Circle().fill(StorageTreemapView.tint(index)).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(storageName(item.url)).lineLimit(1).truncationMode(.middle)
                    if item.isPartial {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 9))
                            .foregroundStyle(.secondary).help(L10n.text("部分内容未计入"))
                    }
                    Spacer(minLength: 1)
                    Text(storageSize(item.bytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    if item.isDirectory {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.isDirectory ? L10n.text("进入") : L10n.text("选择")) \(storageName(item.url))，\(storageSize(item.bytes))")
            .help(item.url.path)
        }
        .padding(.horizontal, 5)
        .frame(height: 31)
        .background(browser.selection == item.url ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .storageContext(for: item, browser: browser, onReview: reviewItem)
    }

    private var unavailable: some View {
        Group {
            if browser.isScanning {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在分析文件夹…")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder(browser.scanMessage ?? L10n.text("重新分析此文件夹"), image: "folder")
            }
        }
        .frame(minHeight: 135)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private func placeholder(_ label: String, image: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: image).font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
            Text(label).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 17)).foregroundStyle(
                !browser.queued.isEmpty ? Color.accentColor : .secondary
            ).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.isTrashing ? L10n.text("正在移到废纸篓…") : reviewTitle)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                if !browser.isTrashing {
                    Text(browser.queued.isEmpty ? L10n.text("点按项目旁的加号。") : L10n.text("审阅所选项目后，可移到废纸篓。"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if browser.isTrashing {
                ProgressView().controlSize(.small)
            } else {
                Button(L10n.text("取消选择"), action: browser.clearQueue).disabled(browser.queued.isEmpty)
                Button(L10n.text("审阅…")) { review = Review(items: browser.queued) }
                    .buttonStyle(.borderedProminent)
                    .disabled(browser.queued.isEmpty)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(minHeight: 52)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.34)) }
    }

    private var reviewTitle: String {
        if browser.queued.isEmpty { return browser.cleanupMessage ?? L10n.text("加入待删除清单") }
        return L10n.text("已选 %@ 项 · %@", browser.queued.count, storageSize(storageTotal(browser.queued)))
    }

    private func reviewItem(_ item: StorageItem) {
        if item.canTrash, !browser.isTrashing { review = Review(items: [item]) }
    }

    private func chooseFolder() {
        let picker = NSOpenPanel()
        picker.title = L10n.text("选择要分析的文件夹")
        picker.prompt = L10n.text("分析")
        picker.directoryURL = browser.directory ?? FileManager.default.homeDirectoryForCurrentUser
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url { browser.choose(url) }
    }
}

@MainActor
struct StorageQueueButton: View {
    let item: StorageItem
    @ObservedObject var browser: StorageBrowser
    var onTile = false

    var body: some View {
        if !item.canTrash {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(onTile ? Color.white : .secondary)
                .frame(width: 22, height: 22)
                .accessibilityLabel(L10n.text("受保护"))
                .help(L10n.text("受保护的项目"))
        } else if browser.isCovered(item) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(onTile ? Color.white : .secondary)
                .frame(width: 22, height: 22)
                .accessibilityLabel(L10n.text("已随上级文件夹加入"))
        } else {
            let queued = browser.isQueued(item)
            Button {
                if queued { browser.removeFromQueue(item.url) }
                else { browser.addToQueue(item) }
            } label: {
                Image(systemName: queued ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(onTile ? Color.white : .accentColor)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(queued ? L10n.text("从待删除清单移除 %@", storageName(item.url)) : L10n.text("加入待删除清单 %@", storageName(item.url)))
            .help(queued ? L10n.text("从待删除清单移除") : L10n.text("加入待删除清单"))
        }
    }
}

private struct StorageReviewSheet: View {
    let items: [StorageItem]
    let root: URL?
    let onClose: () -> Void
    let onTrash: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("审阅待删除项目")).font(.title3.weight(.semibold))
            Text(L10n.text("%@ 项 · 扫描时占用 %@", items.count, storageSize(storageTotal(items))))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(storageName(item.url)).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                Text(relativeName(item.url)).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle).help(item.url.path)
                                if item.isPartial {
                                    Label(L10n.text("部分内容未计入"), systemImage: "exclamationmark.circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(storageSize(item.bytes)).foregroundStyle(.secondary).font(.caption.monospacedDigit()).fixedSize()
                        }.padding(8)
                        if item.id != items.last?.id { Divider() }
                    }
                }
            }
            .frame(height: CGFloat(min(250, max(65, items.count * 56))))
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            Text(L10n.text("可以从废纸篓恢复这些项目。")).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.text("取消"), action: onClose).keyboardShortcut(.cancelAction)
                Button(L10n.text("移到废纸篓"), role: .destructive, action: onTrash).buttonStyle(.borderedProminent)
            }
        }
        .padding(19)
        .frame(width: 470)
    }

    private func relativeName(_ url: URL) -> String {
        guard let root else { return url.path }
        let parts = url.deletingLastPathComponent().pathComponents.dropFirst(root.pathComponents.count)
        return ([storageName(root)] + parts).joined(separator: " / ")
    }
}

func storageName(_ url: URL) -> String {
    url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
}

func storageSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func storageTotal(_ items: [StorageItem]) -> Int64 {
    items.reduce(0) { $0 + min(Int64.max - $0, $1.bytes) }
}

extension View {
    @MainActor
    func storageContext(for item: StorageItem, browser: StorageBrowser, onReview: @escaping (StorageItem) -> Void) -> some View {
        contextMenu {
            if item.isDirectory { Button(L10n.text("进入文件夹")) { browser.open(item) } }
            Button(L10n.text("在 Finder 显示")) { browser.reveal(item) }
            if item.canTrash {
                if browser.isQueued(item) {
                    Button(L10n.text("从待删除清单移除")) { browser.removeFromQueue(item.url) }
                } else if !browser.isCovered(item) {
                    Button(L10n.text("加入待删除清单")) { browser.addToQueue(item) }
                }
                Button(L10n.text("移到废纸篓…"), role: .destructive) { onReview(item) }
            }
        }
    }
}
