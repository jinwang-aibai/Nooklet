import CoreGraphics
import NookletCore

func checkMenuBarLayout() throws {
    try expect(MenuBarExpansion.collapsed.shows(.visible))
    try expectFalse(MenuBarExpansion.collapsed.shows(.hidden))
    try expect(MenuBarExpansion.hidden.shows(.hidden))
    try expectFalse(MenuBarExpansion.hidden.shows(.alwaysHidden))
    try expect(MenuBarExpansion.all.shows(.alwaysHidden))

    // A notched display on the right and below the primary display. The same
    // group fits on the external display but crosses the camera on the laptop.
    let laptop = CGRect(x: 1920, y: -92, width: 1728, height: 1117)
    let visible = CGRect(x: 1920, y: -92, width: 1728, height: 1085)
    let nearNotch = CGRect(x: 3010, y: 993, width: 29, height: 32)
    try expectNil(MenuBarLayout.inlineFrame(anchor: nearNotch, safeLeft: 2876.5, obstacles: [], width: 146))
    let external = CGRect(x: 1490, y: 1050, width: 28, height: 30)
    let inline = MenuBarLayout.inlineFrame(anchor: external, safeLeft: 330, obstacles: [], width: 146)
    try expectEqual(inline, CGRect(x: 1340, y: 1050, width: 146, height: 30))
    let nativeOverflow = CGRect(x: 1450, y: 1050, width: 25, height: 30)
    try expectEqual(MenuBarLayout.inlineFrame(anchor: external, safeLeft: 330, obstacles: [nativeOverflow], width: 146),
                    CGRect(x: 1300, y: 1050, width: 146, height: 30))

    let liveMeter = CGRect(x: 2934, y: 993, width: 76, height: 32)
    try expectNil(MenuBarLayout.inlineFrame(anchor: nearNotch, safeLeft: 2876.5, obstacles: [liveMeter], width: 64))
    let furtherRight = CGRect(x: 3086, y: 993, width: 24, height: 32)
    let meterBesideArrow = CGRect(x: 3010, y: 993, width: 76, height: 32)
    try expectEqual(MenuBarLayout.inlineFrame(anchor: furtherRight, safeLeft: 2876.5, obstacles: [meterBesideArrow], width: 64),
                    CGRect(x: 2942, y: 993, width: 64, height: 32))
    let anchor = CGRect(x: 3580, y: 993, width: 29, height: 32)
    let size = CGSize(width: 270, height: 90)
    let origin = MenuBarLayout.shelfOrigin(display: laptop, usable: visible, safeTop: 32, anchor: anchor, size: size)
    try expectEqual(origin, CGPoint(x: 3310, y: 895))
    try expect(visible.contains(CGRect(origin: origin, size: size)))

    // A display left of the primary has negative global X coordinates.
    let left = CGRect(x: -1280, y: 0, width: 1280, height: 800)
    let top = CGRect(x: -1278, y: 776, width: 24, height: 24)
    let leftOrigin = MenuBarLayout.shelfOrigin(display: left, usable: left, safeTop: 0, anchor: top, size: size)
    try expectEqual(leftOrigin.x, -1272)
    try expect(left.contains(CGRect(origin: leftOrigin, size: size)))
}
