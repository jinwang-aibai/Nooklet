import AppKit
import NookletCore

@MainActor
final class IslandController: NSObject {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let metrics: [StatusMetric]
    var onOpen: (() -> Void)?

    init(metrics: Set<StatusMetric>) {
        self.metrics = StatusMetric.allCases.filter(metrics.contains)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = L10n.text("Nooklet 灵动岛")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        let shell = NSView()
        shell.wantsLayer = true
        shell.layer?.backgroundColor = NSColor(srgbRed: 0.075, green: 0.10, blue: 0.15, alpha: 0.98).cgColor
        shell.layer?.cornerRadius = 15
        label.textColor = NSColor(srgbRed: 0.90, green: 0.97, blue: 1, alpha: 1)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        let button = NSButton(title: "", target: self, action: #selector(open))
        button.isBordered = false
        button.setAccessibilityLabel(L10n.text("打开灵动岛设置"))
        shell.addSubview(label)
        shell.addSubview(button)
        label.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -12),
            button.topAnchor.constraint(equalTo: shell.topAnchor),
            button.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
        ])
        panel.contentView = shell
        place()
        panel.orderFrontRegardless()
    }

    func render(_ readings: [StatusMetric: MetricReading]) {
        let title = metrics.map { "\($0.title) \(readings[$0]?.value ?? "—")" }.joined(separator: "   ·   ")
        if label.stringValue != title { label.stringValue = title }
    }

    func place() {
        guard let screen = NSScreen.screens.first else { return }
        let width = min(screen.visibleFrame.width - 20, CGFloat(max(180, metrics.count * 108)))
        let y = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: y - 34, width: width, height: 30), display: true)
    }

    func close() { panel.orderOut(nil) }
    @objc private func open() { onOpen?() }
}
