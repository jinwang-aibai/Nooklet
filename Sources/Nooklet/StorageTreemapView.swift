import NookletCore
import SwiftUI

@MainActor
struct StorageTreemapView: View {
    private struct Tile: Identifiable {
        enum ID: Hashable {
            case item(URL)
            case other(URL)
        }

        let id: ID
        let item: StorageItem?
        let bytes: Int64
        let rect: CGRect
        let colorIndex: Int?
        let depth: Int
        var hasChildren = false
    }

    private struct Entry {
        let item: StorageItem?
        let bytes: Int64
        let colorIndex: Int?
    }

    let scan: StorageScan
    @ObservedObject var browser: StorageBrowser
    let onReview: (StorageItem) -> Void

    static func tint(_ index: Int) -> Color {
        let colors = [
            Color(red: 0.57, green: 0.27, blue: 0.36),
            Color(red: 0.60, green: 0.36, blue: 0.24),
            Color(red: 0.49, green: 0.42, blue: 0.21),
            Color(red: 0.33, green: 0.44, blue: 0.29),
            Color(red: 0.25, green: 0.43, blue: 0.43),
            Color(red: 0.32, green: 0.44, blue: 0.58),
            Color(red: 0.43, green: 0.35, blue: 0.58),
            Color(red: 0.51, green: 0.35, blue: 0.48),
        ]
        return colors[index % colors.count]
    }

    var body: some View {
        GeometryReader { canvas in
            let bounds = CGRect(origin: .zero, size: canvas.size).insetBy(dx: 3, dy: 3)
            let tiles = layout(scan.items, total: scan.totalBytes, parent: scan.directory, bounds: bounds)
            ZStack(alignment: .topLeading) {
                if tiles.isEmpty {
                    Text(L10n.text("没有可绘制的磁盘占用")).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(tiles) { tile in
                        tileView(tile)
                            .frame(width: tile.rect.width, height: tile.rect.height)
                            .position(x: tile.rect.midX, y: tile.rect.midY)
                    }
                }
            }
            .frame(width: canvas.size.width, height: canvas.size.height)
        }
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("空间占用图"))
    }

    @ViewBuilder
    private func tileView(_ tile: Tile) -> some View {
        let tint = tile.colorIndex.map(Self.tint) ?? Color.secondary
        if let item = tile.item, tile.rect.width >= 12, tile.rect.height >= 12 {
            StorageMapItem(tile: tile, item: item, tint: tint, browser: browser,
                           onReview: onReview)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.opacity(tile.depth == 0 ? 0.67 : 0.84))
                .overlay(alignment: .topLeading) {
                    if tile.item == nil, tile.rect.width >= 45, tile.rect.height >= 23 {
                        Text(L10n.text("其他")).font(.caption.weight(.semibold)).foregroundStyle(.white).padding(4)
                    }
                }
                .help(tile.item == nil ? L10n.text("其他 · %@", storageSize(tile.bytes)) : storageSize(tile.bytes))
                .accessibilityHidden(true)
        }
    }

    private func layout(_ items: [StorageItem], total: Int64, parent: URL, bounds: CGRect,
                        depth: Int = 0, tint: Int? = nil) -> [Tile] {
        let limit = depth == 0 ? 38 : 12
        var entries = items.prefix(limit).enumerated().compactMap { index, item in
            item.bytes > 0 ? Entry(item: item, bytes: item.bytes, colorIndex: tint ?? index) : nil
        }
        let represented = entries.reduce(Int64(0)) { $0 + min(Int64.max - $0, $1.bytes) }
        if total > represented {
            entries.append(Entry(item: nil, bytes: total - represented, colorIndex: tint))
            entries.sort { $0.bytes > $1.bytes }
        }
        let rectangles = StorageTreemap.rectangles(weights: entries.map { Double($0.bytes) }, in: bounds)

        var tiles: [Tile] = []
        for (entry, region) in zip(entries, rectangles) {
            let gap: CGFloat = depth == 0 ? 1.2 : 0.8
            guard region.width > gap * 2, region.height > gap * 2 else { continue }
            let rect = region.insetBy(dx: gap, dy: gap)
            var tile = Tile(id: entry.item.map { .item($0.url) } ?? .other(parent), item: entry.item,
                            bytes: entry.bytes, rect: rect, colorIndex: entry.colorIndex, depth: depth)
            if let item = entry.item, !item.children.isEmpty, rect.width >= 67, rect.height >= 77 {
                let header = rect.height >= 100 ? 39.0 : 23.0
                let childArea = CGRect(x: rect.minX + 3, y: rect.minY + header,
                                       width: rect.width - 6, height: rect.height - header - 3)
                let children = layout(item.children, total: item.bytes, parent: item.url,
                                      bounds: childArea, depth: depth + 1, tint: entry.colorIndex)
                tile.hasChildren = !children.isEmpty
                tiles.append(tile)
                tiles.append(contentsOf: children)
            } else {
                tiles.append(tile)
            }
        }
        return tiles
    }

    @MainActor
    private struct StorageMapItem: View {
        let tile: Tile
        let item: StorageItem
        let tint: Color
        @ObservedObject var browser: StorageBrowser
            let onReview: (StorageItem) -> Void
        @State private var hovered = false

        private var selected: Bool { browser.selection == item.url || browser.isQueued(item) }
        private var roomy: Bool { tile.rect.width >= 70 && tile.rect.height >= 23 }

        var body: some View {
            Button { browser.open(item) } label: {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5).fill(tint)
                    RoundedRectangle(cornerRadius: 5).fill(.black.opacity(Double(tile.depth) * 0.075))
                    if hovered { RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.11)) }
                    if tile.rect.width >= 32, tile.rect.height >= 17 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(storageName(item.url))
                                .font(.system(size: tile.rect.width >= 120 ? 12 : 10, weight: .semibold))
                                .lineLimit(1).truncationMode(.middle)
                            if tile.rect.width >= 56, tile.rect.height >= 37, !tile.hasChildren || tile.rect.height >= 100 {
                                Text(storageSize(item.bytes))
                                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.84))
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.leading, 5).padding(.top, 4).padding(.trailing, roomy ? 24 : 4)
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(selected ? 1 : 0.33), lineWidth: selected ? 2 : 0.8) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.isDirectory ? L10n.text("进入") : L10n.text("选择")) \(storageName(item.url))，\(storageSize(item.bytes))")
            .help(item.url.path)
            .overlay(alignment: .topTrailing) {
                if roomy, hovered || selected || !item.canTrash {
                    StorageQueueButton(item: item, browser: browser, onTile: true)
                        .padding(.trailing, 1)
                }
            }
            .onHover { hovered = $0 }
            .storageContext(for: item, browser: browser, onReview: onReview)
        }
    }
}
