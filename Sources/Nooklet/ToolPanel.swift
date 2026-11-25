import AppKit

@MainActor
class ToolPanel: NSViewController {
    private let heading: String
    private let detail: String

    init(heading: String, detail: String) {
        self.heading = heading
        self.detail = detail
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = NSView()
        let title = panelTitle(heading, symbol: symbol)
        let subtitle = NSTextField(wrappingLabelWithString: detail)
        subtitle.textColor = ToolboxAppearance.secondary
        subtitle.font = .systemFont(ofSize: 13)
        let header = makeStack(detail.isEmpty ? [title] : [title, subtitle], spacing: 8)
        let body = makeBody()
        header.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        container.addSubview(body)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
        ])
        if !detail.isEmpty {
            subtitle.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
            subtitle.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        view = container
    }

    var symbol = "square.grid.2x2"

    func makeBody() -> NSView { NSView() }
    func setVisible(_ visible: Bool) {}
    func endUse() { setVisible(false) }
}

@MainActor
func makeStack(_ views: [NSView], axis: NSUserInterfaceLayoutOrientation = .vertical, spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = axis
    stack.alignment = axis == .vertical ? .leading : .centerY
    stack.spacing = spacing
    return stack
}

@MainActor
func topAligned(_ stack: NSStackView) -> NSView {
    let container = NSView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: container.topAnchor),
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
    ])
    return container
}

@MainActor
func listScrollView(_ table: NSTableView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    table.backgroundColor = .clear
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = table
    return scroll
}

@MainActor
func listLabel(_ title: String, alignment: NSTextAlignment = .left, monospaced: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: title)
    label.textColor = ToolboxAppearance.ink
    label.alignment = alignment
    label.lineBreakMode = .byTruncatingMiddle
    if monospaced { label.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
    return label
}


@MainActor
func panelTitle(_ title: String, symbol: String) -> NSView {
    let name = NSTextField(labelWithString: title)
    name.font = .systemFont(ofSize: 25, weight: .bold)
    name.textColor = ToolboxAppearance.ink
    let icon = shareIcon(symbol, size: 17, color: ToolboxAppearance.blue)
    icon.setAccessibilityElement(false)
    let badge = shareSurface(icon, inset: 7, radius: 9, tint: .accent)
    return makeStack([badge, name], axis: .horizontal, spacing: 10)
}
