import AppKit
import ApplicationServices

struct MenuBarExtra: Sendable {
    let label: String
    let pid: pid_t
    let frame: CGRect
}

struct MenuBarApp: Identifiable {
    static let inputMenuID = "com.apple.TextInputMenuAgent"
    static let sogouID = "com.sogou.inputmethod.sogou"

    let id: String
    let name: String
    let icon: NSImage?
    var iconSource: String? = nil
    let system: Bool
    var extras: [MenuBarExtra]

    var isInputMenu: Bool { id == Self.inputMenuID }
    var canMove: Bool { !system || isInputMenu }
}

struct MenuBarInventory: Sendable {
    struct Result: Sendable {
        var extras: [pid_t: [MenuBarExtra]]
        var agentItems: [MenuBarExtra]
    }

    static func read(pids: [pid_t], agent: pid_t?) async -> Result {
        await Task.detached(priority: .utility) {
            await withTaskGroup(of: (pid_t, [MenuBarExtra]).self) { group in
                // Batch the AX queries so a hung app never stalls the UI or starts
                // a large number of simultaneous WindowServer requests.
                var pids = pids.makeIterator()
                for _ in 0..<10 {
                    guard let pid = pids.next() else { break }
                    group.addTask { (pid, Self.extras(of: pid)) }
                }
                var items: [pid_t: [MenuBarExtra]] = [:]
                for await (pid, extras) in group {
                    if !extras.isEmpty { items[pid] = extras }
                    if let next = pids.next() { group.addTask { (next, Self.extras(of: next)) } }
                }
                return Result(extras: items, agentItems: agent.map(Self.agentItems) ?? [])
            }
        }.value
    }

    private static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.18)
        return app
    }

    private static func extras(of pid: pid_t) -> [MenuBarExtra] {
        let app = application(pid)
        guard let bar = element(app, "AXExtrasMenuBar") else { return [] }
        return children(bar).enumerated().map { index, wrapper in
            extra(from: wrapper, fallbackPID: pid, fallbackLabel: L10n.text("菜单栏项目 %@", index + 1))
        }
    }

    private static func extra(from wrapper: AXUIElement, fallbackPID: pid_t, fallbackLabel: String) -> MenuBarExtra {
        var item = wrapper
        for _ in 0..<3 {
            let role = value(item, kAXRoleAttribute) as? String
            guard role == nil || role == kAXGroupRole || role == kAXUnknownRole,
                  let child = children(item).first else { break }
            item = child
        }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].lazy.compactMap { key in
            (value(item, key) as? String)?.split(whereSeparator: \.isNewline).first.map(String.init)
        }.first ?? fallbackLabel
        var pid = fallbackPID
        AXUIElementGetPid(item, &pid)
        return MenuBarExtra(label: label, pid: pid, frame: frame(wrapper) ?? frame(item) ?? .zero)
    }

    private static func agentItems(_ pid: pid_t) -> [MenuBarExtra] {
        let agent = application(pid)
        let windows = (value(agent, kAXWindowsAttribute) as? [AXUIElement]).flatMap { $0.isEmpty ? nil : $0 }
            ?? children(agent)
        return windows.flatMap { window in
            children(window).compactMap { container in
                let item = extra(from: container, fallbackPID: pid, fallbackLabel: "")
                return item.frame.isEmpty ? nil : item
            }
        }
    }

    static func readAgentItems(_ pid: pid_t) async -> [MenuBarExtra] {
        await Task.detached(priority: .userInitiated) { agentItems(pid) }.value
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(parent, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func children(_ item: AXUIElement) -> [AXUIElement] {
        value(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func frame(_ item: AXUIElement) -> CGRect? {
        var rect = CGRect.zero
        if let raw = value(item, "AXFrame"), CFGetTypeID(raw) == AXValueGetTypeID(),
           AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 {
            return rect
        }
        guard let position = value(item, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(item, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &rect.origin),
              AXValueGetValue(size as! AXValue, .cgSize, &rect.size),
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }
}
