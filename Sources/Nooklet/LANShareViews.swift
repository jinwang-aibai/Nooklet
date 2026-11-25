import AppKit

@MainActor
func shareLabel(_ title: String, size: CGFloat, weight: NSFont.Weight = .regular,
                color: NSColor = ToolboxAppearance.ink) -> NSTextField {
    let field = listLabel(title)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    return field
}

@MainActor
func shareIcon(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    let view = NSImageView(image: image ?? NSImage())
    view.contentTintColor = color
    view.widthAnchor.constraint(equalToConstant: size + 3).isActive = true
    view.heightAnchor.constraint(equalToConstant: size + 3).isActive = true
    return view
}

@MainActor
func shareSpacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
    return view
}

@MainActor
func pinShareView(_ child: NSView, to parent: NSView, horizontal: CGFloat = 0, vertical: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: horizontal),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -horizontal),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: vertical),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -vertical),
    ])
}

@MainActor
func shareSurface(_ child: NSView, inset: CGFloat, radius: CGFloat, tint: LANSurface.Tint) -> NSView {
    let view = LANSurface(radius: radius, tint: tint)
    pinShareView(child, to: view, horizontal: inset, vertical: inset)
    return view
}

@MainActor
final class LANSurface: NSView {
    enum Tint { case muted, accent, plain }
    private let radius: CGFloat
    private let tint: Tint

    init(radius: CGFloat, tint: Tint) {
        self.radius = radius
        self.tint = tint
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let color: NSColor
        switch tint {
        case .muted: color = ToolboxAppearance.card
        case .accent: color = ToolboxAppearance.selection
        case .plain: color = ToolboxAppearance.raised
        }
        color.setFill()
        path.fill()
        if tint != .accent {
            ToolboxAppearance.rule.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class LANFileDropSurface: NSView {
    var isEmpty = true { didSet { needsDisplay = true } }
    var highlighted = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        let color = highlighted ? NSColor.controlAccentColor : NSColor.labelColor
        color.withAlphaComponent(highlighted ? 0.075 : (isEmpty ? 0.018 : 0.013)).setFill()
        path.fill()
        color.withAlphaComponent(highlighted ? 0.85 : (isEmpty ? 0.17 : 0.09)).setStroke()
        path.lineWidth = highlighted ? 1.5 : 1
        if isEmpty && !highlighted { path.setLineDash([4, 4], count: 2, phase: 0) }
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class LANDropZone: NSView {
    var onDrop: (([URL]) -> Bool)?
    var onHighlight: ((Bool) -> Void)?
    private var highlighted = false {
        didSet { if highlighted != oldValue { onHighlight?(highlighted) } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        highlighted = sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return highlighted ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { highlighted ? .copy : [] }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlighted = false }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { highlighted }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        return onDrop?(urls) ?? false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) { highlighted = false }
}

@MainActor
final class LANStatusDot: NSView {
    var tint = NSColor.tertiaryLabelColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        tint.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class LANShareCell: NSTableCellView {
    private var hoverTracking: NSTrackingArea?
    private var hovered = false

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if hovered {
            NSColor.controlAccentColor.withAlphaComponent(0.055).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
    }
}

@MainActor
final class LANTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let origin = textContainerOrigin
        (L10n.text("在这里输入，或按 ⌘V 粘贴…") as NSString).draw(
            at: NSPoint(x: origin.x + (textContainer?.lineFragmentPadding ?? 0), y: origin.y),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]
        )
    }
}
