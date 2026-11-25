import AppKit
import NookletCore

@MainActor
final class DisplaySettingsPanel: ToolPanel {
    private let model: ToolboxModel
    private let metrics: [StatusMetric] = [.cpu, .memory, .disk, .battery, .thermal]
    private var metricButtons: [StatusMetric: NSSwitch] = [:]
    private let preview = NSTextField(labelWithString: "")
    private var toggle: NSButton?

    init(model: ToolboxModel) {
        self.model = model
        super.init(heading: L10n.text("灵动岛"), detail: L10n.text("在屏幕顶部显示所选指标。"))
    }

    required init?(coder: NSCoder) { nil }

    override func makeBody() -> NSView {
        let check = NSButton(checkboxWithTitle: L10n.text("在屏幕顶部显示"), target: self, action: #selector(changeToggle(_:)))
        check.font = .systemFont(ofSize: 14, weight: .semibold)
        toggle = check
        let cards: [NSView] = metrics.map { metric in
            let toggle = NSSwitch()
            toggle.target = self
            toggle.action = #selector(changeMetric(_:))
            toggle.controlSize = .small
            toggle.setAccessibilityLabel(metric.title)
            metricButtons[metric] = toggle
            let icon = NSImageView(image: NSImage(systemSymbolName: metric.symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = metric.color
            icon.widthAnchor.constraint(equalToConstant: 23).isActive = true
            let label = NSTextField(labelWithString: metric.title)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            let row = makeStack([icon, label, NSView(), toggle], axis: .horizontal, spacing: 10)
            row.edgeInsets = NSEdgeInsets(top: 9, left: 15, bottom: 9, right: 15)
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 39).isActive = true
            return row
        }
        let group = makeStack(cards, spacing: 0)
        group.wantsLayer = true
        group.layer?.cornerRadius = 14
        group.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
        for card in cards { card.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
        let rows: [NSView] = [makePreview(), check, group]
        let stack = makeStack(rows, spacing: 16)
        for row in rows where !(row is NSButton) {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refresh()
        return topAligned(stack)
    }

    private func makePreview() -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.fillColor = NSColor(srgbRed: 0.10, green: 0.16, blue: 0.27, alpha: 1)
        box.borderWidth = 0
        box.cornerRadius = 15
        box.contentViewMargins = .zero
        let symbol = "capsule"
        let mark = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        mark.contentTintColor = NSColor(srgbRed: 0.68, green: 0.91, blue: 0.86, alpha: 1)
        mark.widthAnchor.constraint(equalToConstant: 32).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let title = NSTextField(labelWithString: L10n.text("屏幕顶部 · 指标预览"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = NSColor.white.withAlphaComponent(0.7)
        preview.font = .systemFont(ofSize: 17, weight: .semibold)
        preview.textColor = .white
        preview.lineBreakMode = .byTruncatingTail
        let text = makeStack([title, preview], spacing: 5)
        let row = makeStack([mark, text], axis: .horizontal, spacing: 14)
        if let body = box.contentView {
            row.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: body.topAnchor, constant: 17),
                row.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -17),
                row.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 17),
                row.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -17),
            ])
        }
        return box
    }

    func refresh() {
        let prefs = model.preferences
        for (metric, check) in metricButtons { check.state = prefs.island.contains(metric) ? .on : .off }
        let selected = metrics.filter(prefs.island.contains)
        preview.stringValue = selected.isEmpty ? L10n.text("尚未选择指标") : selected.map(\.title).joined(separator: "  ·  ")
        toggle?.state = prefs.islandEnabled ? .on : .off
    }

    @objc private func changeMetric(_ sender: NSSwitch) {
        guard let metric = metricButtons.first(where: { $0.value === sender })?.key else { return }
        model.updateDisplay { prefs in
            if sender.state == .on { prefs.island.insert(metric) } else { prefs.island.remove(metric) }
        }
    }

    @objc private func changeToggle(_ sender: NSButton) {
        model.updateDisplay { $0.islandEnabled = sender.state == .on }
    }
}
