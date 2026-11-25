import SwiftUI

enum WorkspaceTint {
    case accent, neutral, success, warning, danger

    var foreground: Color {
        let color: NSColor = switch self {
        case .accent: ToolboxAppearance.blue
        case .neutral: ToolboxAppearance.secondary
        case .success: ToolboxAppearance.teal
        case .warning: ToolboxAppearance.amber
        case .danger: ToolboxAppearance.red
        }
        return Color(nsColor: color)
    }
}

struct WorkspaceActionStyle: ButtonStyle {
    var tint: WorkspaceTint = .accent
    var prominent = false
    var onTerminal = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        let active = enabled && hovering
        let foreground = onTerminal ? (tint == .danger ? WorkspaceTerminal.error : WorkspaceTerminal.foreground) : tint.foreground
        let opacity = configuration.isPressed ? 0.25 : active ? 0.17 : 0.11
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(minHeight: 27)
            .foregroundStyle(prominent ? Color.white : foreground)
            .background(prominent ? Color(nsColor: ToolboxAppearance.blueFill).opacity(configuration.isPressed ? 0.75 : 1) : foreground.opacity(opacity), in: shape)
            .overlay { shape.strokeBorder((prominent ? .white : foreground).opacity(active ? 0.23 : 0.09)).allowsHitTesting(false) }
            .opacity(enabled ? 1 : 0.47)
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

struct WorkspaceGlyph: View {
    let symbol: String
    let tint: WorkspaceTint
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint.foreground)
            .frame(width: size, height: size)
            .background(tint.foreground.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

struct WorkspaceField: View {
    let title: String
    let symbol: String
    @Binding var text: String
    var tint: WorkspaceTint = .accent
    var monospaced = false
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint.foreground)
                .accessibilityHidden(true)
            TextField(title, text: $text)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textFieldStyle(.plain)
                .focused($focused)
        }
        .padding(.horizontal, 9)
        .frame(height: 29)
        .background(Color(nsColor: ToolboxAppearance.card), in: shape)
        .overlay { shape.strokeBorder(focused ? tint.foreground : Color(nsColor: ToolboxAppearance.rule)).allowsHitTesting(false) }
    }
}

enum WorkspaceTerminal {
    static let background = color(0x111721)
    static let header = color(0x202A38)
    static let foreground = color(0xDCE5F3)
    static let subdued = color(0x9AAEC9)
    static let accent = color(0x8AB7FF)
    static let selection = color(0x2A4A78)
    static let success = color(0x8DCBB8)
    static let warning = color(0xE5BC79)
    static let error = color(0xF0A8B3)
    static let keyword = color(0xADC7FF)
    static let literal = color(0xB1D8F2)
    static let option = color(0xB7C8E1)

    private static func color(_ hex: UInt32) -> Color {
        Color(nsColor: ToolboxAppearance.rgb(hex))
    }
}
