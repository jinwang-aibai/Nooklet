import CoreGraphics

public enum MenuBarVisibility: String, Codable, CaseIterable, Sendable {
    case visible, hidden, alwaysHidden
}

public enum MenuBarExpansion: Sendable {
    case collapsed, hidden, all

    public func shows(_ rule: MenuBarVisibility) -> Bool {
        switch rule {
        case .visible: true
        case .hidden: self != .collapsed
        case .alwaysHidden: self == .all
        }
    }
}

public enum MenuBarLayout {
    /// Use the nearest free segment to the left, including gaps beyond
    /// visible status items such as the live network meter.
    public static func inlineFrame(anchor: CGRect, safeLeft: CGFloat, obstacles: [CGRect],
                                   width: CGFloat) -> CGRect? {
        guard width > 0, anchor.height > 0 else { return nil }
        let gap: CGFloat = 4
        let left = safeLeft + gap
        var right = anchor.minX - gap
        let occupied = obstacles
            .filter { $0.minY < anchor.maxY && $0.maxY > anchor.minY }
            .map { $0.insetBy(dx: -gap, dy: 0) }
            .sorted { $0.maxX > $1.maxX }

        for item in occupied where item.minX < right && item.maxX > left {
            if right - max(item.maxX, left) >= width { break }
            right = item.minX
        }
        guard right - left >= width else { return nil }
        return CGRect(x: right - width, y: anchor.minY, width: width, height: anchor.height)
    }

    public static func shelfOrigin(display: CGRect, usable: CGRect, safeTop: CGFloat,
                                   anchor: CGRect, size: CGSize) -> CGPoint {
        let edge: CGFloat = 8
        let right = usable.maxX - edge
        let left = usable.minX + edge
        let x = max(left, min(anchor.minX - size.width, right - size.width))
        let top = min(anchor.minY, usable.maxY, display.maxY - safeTop)
        let y = max(usable.minY + edge, top - size.height - edge)
        return CGPoint(x: x, y: y)
    }
}
