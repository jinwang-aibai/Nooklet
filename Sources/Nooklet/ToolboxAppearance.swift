import AppKit
import NookletCore
import SwiftUI

extension GeneralPreferences {
    var appearance: NSAppearance? {
        switch theme {
        case .system, .custom: nil
        case .black: NSAppearance(named: .darkAqua)
        case .white: NSAppearance(named: .aqua)
        }
    }

    var accent: NSColor? { theme == .custom ? ToolboxAppearance.rgb(customColor) : nil }

    func tint(_ base: NSColor, amount: CGFloat) -> NSColor {
        guard let accent else { return base }
        return NSColor(name: nil) { appearance in
            var tinted = base
            appearance.performAsCurrentDrawingAppearance {
                tinted = base.blended(withFraction: amount, of: accent) ?? base
            }
            return tinted
        }
    }
}

enum ToolboxAppearance {
    static let window = adaptive("Window", light: 0xF7F9FC, dark: 0x161C26)
    static let sidebar = adaptive("Sidebar", light: 0xEDF1F7, dark: 0x111721)
    static let card = adaptive("Card", light: 0xFFFFFF, dark: 0x202A38)
    static let raised = adaptive("Raised", light: 0xF0F4FA, dark: 0x283447)
    static let ink = adaptive("Ink", light: 0x1D293D, dark: 0xECF2FC)
    static let secondary = adaptive("Secondary", light: 0x536379, dark: 0xB1BED2)
    static let rule = adaptive("Rule", light: 0xD8E0EB, dark: 0x37465B)
    static let selection = adaptive("Selection", light: 0xDDEAFE, dark: 0x283E60)
    static let blue = adaptive("Blue", light: 0x1656C8, dark: 0x8AB7FF)
    static let blueFill = rgb(0x2457B1)
    static let green = adaptive("Green", light: 0x398E21, dark: 0x86CC63)
    static let orange = adaptive("Orange", light: 0xCC4E06, dark: 0xFF9858)
    static let amber = adaptive("Amber", light: 0xA96200, dark: 0xF1B657)
    static let teal = adaptive("Teal", light: 0x08786B, dark: 0x73D8C4)
    static let red = adaptive("Red", light: 0xAD293F, dark: 0xFFA3B0)
    static let violet = adaptive("Violet", light: 0x7F32DE, dark: 0xBC91FF)

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("Nooklet.\(name)")) { appearance in
            rgb(isDark(appearance) ? dark : light)
        }
    }
}

extension View {
    func toolboxCard(radius: CGFloat = 11) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return background(Color(nsColor: ToolboxAppearance.card), in: shape)
            .overlay {
                shape.strokeBorder(Color(nsColor: ToolboxAppearance.rule))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

struct ToolIconButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.13 : hovered ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}
