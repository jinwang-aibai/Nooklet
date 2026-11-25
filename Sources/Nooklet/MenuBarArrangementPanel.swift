import AppKit
import NookletCore

@MainActor
final class MenuBarArrangementPanel: NSObject {
    private final class ArrangementWindow: NSPanel {
        var onEscape: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onEscape?() }
    }

    private let panel = ArrangementWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
    private var onAction: (() -> Void)?
    var onClose: (() -> Void)?

    func show(title: String, detail: String, action: String, anchor: CGRect, screen: NSScreen,
              onAction: @escaping () -> Void) {
        self.onAction = onAction
        let heading = shareLabel(title, size: 14, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: detail)
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        let button = NSButton(title: action, target: self, action: #selector(handleAction))
        button.bezelStyle = .rounded
        let width = min(350, screen.visibleFrame.width - 16)
        description.preferredMaxLayoutWidth = width - 28
        let stack = makeStack([heading, description, button], spacing: 8)
        let size = CGSize(width: width, height: stack.fittingSize.height + 24)
        let content = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 13
        content.layer?.masksToBounds = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            content.blendingMode = .withinWindow
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        pinShareView(stack, to: content, horizontal: 14, vertical: 12)

        let origin = MenuBarLayout.shelfOrigin(display: screen.frame, usable: screen.visibleFrame,
                                               safeTop: screen.safeAreaInsets.top, anchor: anchor, size: size)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityLabel(title)
        panel.contentView = content
        panel.onEscape = { [weak self] in self?.onClose?() }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel.orderOut(nil) }
    @objc private func handleAction() { onAction?() }
}
