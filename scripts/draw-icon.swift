import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [CGFloat((rgb >> 16) & 255) / 255, CGFloat((rgb >> 8) & 255) / 255,
                     CGFloat(rgb & 255) / 255, alpha]
    )!
}

private func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!
}

private func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The open upper-right corner holds the accent block.
private func monogram(stroke: CGFloat, accent: CGFloat) -> (CGPath, CGPath) {
    let line = CGMutablePath()
    line.move(to: CGPoint(x: 303, y: 684))
    line.addLine(to: CGPoint(x: 303, y: 346))
    line.addLine(to: CGPoint(x: 710, y: 684))
    line.addLine(to: CGPoint(x: 710, y: 447))
    let ribbon = line.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 2)
    let inset = accent / 2
    let block = rounded(CGRect(x: 710 - inset, y: 301 - inset, width: accent, height: accent),
                        radius: accent * 0.23)
    return (ribbon, block)
}

private func render(size: Int, template: Bool = false) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: scale, y: -scale)

    if template {
        context.translateBy(x: -339, y: -293)
        context.scaleBy(x: 1.68, y: 1.68)
        let (ribbon, block) = monogram(stroke: 105, accent: 108)
        context.addPath(ribbon)
        context.addPath(block)
        context.setFillColor(color(0x000000))
        context.fillPath()
        return context.makeImage()!
    }

    let tileRect = CGRect(x: 103, y: 88, width: 818, height: 818)
    let tile = rounded(tileRect, radius: 188)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -22 * scale), blur: 38 * scale, color: color(0x090F28, alpha: 0.32))
    context.addPath(tile)
    context.setFillColor(color(0x122642))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(gradient([color(0x344F7E), color(0x203658), color(0x101C35)]),
                               start: CGPoint(x: 165, y: 108), end: CGPoint(x: 900, y: 904),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let glow = gradient([color(0x6CBFCF, alpha: 0.23), color(0x6CBFCF, alpha: 0)])
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 261, y: 150), startRadius: 0,
                               endCenter: CGPoint(x: 261, y: 150), endRadius: 650, options: [])
    context.restoreGState()

    context.addPath(rounded(tileRect.insetBy(dx: 2, dy: 2), radius: 186))
    context.setStrokeColor(color(0xCBEEFF, alpha: 0.25))
    context.setLineWidth(4)
    context.strokePath()

    let (ribbon, block) = monogram(stroke: size <= 32 ? 119 : 107, accent: size <= 32 ? 112 : 104)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 22 * scale, color: color(0x061020, alpha: 0.47))
    context.addPath(ribbon)
    context.addPath(block)
    context.setFillColor(color(0xBDDAD9))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(ribbon)
    context.clip()
    context.drawLinearGradient(gradient([color(0xF0F9F6), color(0xC3F5EB), color(0x8BCEC8)]),
                               start: CGPoint(x: 310, y: 307), end: CGPoint(x: 722, y: 739),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    context.saveGState()
    context.addPath(block)
    context.clip()
    context.drawLinearGradient(gradient([color(0xFFDC99), color(0xF9A967)]),
                               start: CGPoint(x: 661, y: 250), end: CGPoint(x: 763, y: 353),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    return context.makeImage()!
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: swift draw-icon.swift <iconset> <menu-bar.png>\n".utf8))
    exit(2)
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let path = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try writePNG(render(size: size * scale), to: path)
    }
}
try writePNG(render(size: 36, template: true), to: URL(fileURLWithPath: CommandLine.arguments[2]))
