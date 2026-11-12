// Renders the Cirrus app icon ("Convergence": cirrus streaks converging on one
// bright point over a high-altitude dawn sky) into Resources/AppIcon.iconset.
// Sizes ≤ 32 px use a simplified drawing with three heavier streaks so the mark
// stays legible in Finder lists and the menu bar.
//
//   swift Scripts/make_icon.swift Resources     (then: iconutil -c icns Resources/AppIcon.iconset)
import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ px: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    // Work in a top-left origin like the SVG design.
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)
    let small = px <= 32

    // Squircle body on the macOS icon grid (824 pt body, 100 pt margins) with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x0A1830, 0.35))
        ctx.addPath(squircle); ctx.setFillColor(rgb(0x14294D)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let sky = CGGradient(colorsSpace: space, colors: [rgb(0x14294D), rgb(0x4D7DB8), rgb(0xBFD3EA), rgb(0xF2C2A0)] as CFArray,
                         locations: [0, 0.5, 0.82, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])

    // Faint high haze band near the horizon.
    let haze = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(haze, start: CGPoint(x: 0, y: 640), end: CGPoint(x: 0, y: 820), options: [])

    let end = CGPoint(x: 790, y: 470)
    // (start y, width, opacity)
    let streaks: [(CGFloat, CGFloat, CGFloat)] = small
        ? [(300, 56, 0.75), (470, 72, 1), (650, 56, 0.75)]
        : [(230, 16, 0.55), (320, 26, 0.7), (410, 38, 1), (520, 30, 0.85), (630, 20, 0.65), (735, 12, 0.45)]
    let fade = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.5), rgb(0xFFFFFF, 1)] as CFArray, locations: [0, 0.4, 1])!
    for (y0, w, a) in streaks {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 40, y: y0))
        let yEnd = end.y + (y0 - end.y) * 0.02
        p.addCurve(to: CGPoint(x: end.x, y: yEnd), control1: CGPoint(x: 360, y: y0), control2: CGPoint(x: 560, y: end.y + (y0 - end.y) * 0.25))
        ctx.saveGState()
        ctx.setAlpha(a)
        ctx.addPath(p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4))
        ctx.clip()
        ctx.drawLinearGradient(fade, start: CGPoint(x: 120, y: 0), end: CGPoint(x: 790, y: 0), options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }
    // The point where everything converges: warm glow, white core.
    if !small {
        let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFF4EA, 0.95), rgb(0xFFE3CC, 0.45), rgb(0xFFE3CC, 0)] as CFArray, locations: [0, 0.25, 1])!
        ctx.drawRadialGradient(glow, startCenter: end, startRadius: 0, endCenter: end, endRadius: 120, options: [])
    }
    ctx.setFillColor(rgb(0xFFFFFF))
    let r: CGFloat = small ? 44 : 15
    ctx.fillEllipse(in: CGRect(x: end.x - r, y: end.y + 1 - r, width: r * 2, height: r * 2))
    ctx.restoreGState()

    // Hairline edge highlight for definition on light backgrounds.
    if !small {
        ctx.addPath(squircle)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.12)); ctx.setLineWidth(3); ctx.strokePath()
    }
    return ctx.makeImage()!
}

func write(_ img: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let px = pt * sc
        let name = sc == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        write(render(px), iconset.appendingPathComponent(name))
    }
}
write(render(1024), outDir.appendingPathComponent("AppIcon-1024.png"))
print("wrote \(iconset.path)")
