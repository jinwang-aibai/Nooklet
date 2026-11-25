import AppKit

@MainActor
enum MenuBarArtwork {
    static func sogouGlyph(_ name: String, in bundle: Bundle?, fallback: String) -> NSImage? {
        let image = (bundle?.image(forResource: name)?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        guard image.isTemplate else { return image }
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
    }
}
