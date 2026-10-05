// Renders Resources/AppIcon.icns from the App icon wireframe (plan, UI/UX Wireframes → App icon).
// Run from the project root. The build works inside the Claude Code sandbox; running needs it disabled,
// because iconutil silently fails inside it:
//   swiftc -module-cache-path "$TMPDIR/mc" scripts/make-icon.swift -o "$TMPDIR/make-icon"
//   "$TMPDIR/make-icon"
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// All values are on the 1024 grid with a top-left origin, as in the wireframe.
func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: 1024) // flip to top-left
    ctx.scaleBy(x: 1, y: -1)

    // Rounded-square tile: 824/1024, radius 185, vertical gradient #5B6B80 (top) → #2B3442 (bottom).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [rgb(0x5B6B80), rgb(0x2B3442)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
    ctx.restoreGState()

    // Display: screen (196,250) 632x392 radius 34, neck and base, all #ECF0F6 at 92%.
    let light = rgb(0xECF0F6, 0.92)
    let shapes: [(CGRect, CGFloat, CGColor)] = [
        (CGRect(x: 196, y: 250, width: 632, height: 392), 34, light),          // screen
        (CGRect(x: 472, y: 642, width: 80, height: 70), 0, light),             // neck
        (CGRect(x: 372, y: 712, width: 280, height: 40), 20, light),           // base
        (CGRect(x: 256, y: 314, width: 228, height: 228), 18, rgb(0x0A84FF)),  // "1x": one large pixel
    ] + [(548, 314), (670, 314), (548, 436), (670, 436)].map { x, y in         // "2x": 2x2 small pixels, gap 16
        (CGRect(x: x, y: y, width: 106, height: 106), 12, rgb(0x2B3442, 0.78))
    }
    for (rect, radius, color) in shapes {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }
    return ctx.makeImage()!
}

let fm = FileManager.default
let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory() // the sandbox's $TMPDIR
let iconset = URL(fileURLWithPath: tmp).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let dest = CGImageDestinationCreateWithURL(iconset.appendingPathComponent(name) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, render(size * scale), nil)
        guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(name)") }
    }
}

let out = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/AppIcon.icns")
try! fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(out.path)")
