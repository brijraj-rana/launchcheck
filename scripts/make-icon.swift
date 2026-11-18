// Renders Resources/AppIcon.icns: a graphite tile with a three-line checklist, two lines passed and one failed.
// Usage: swift scripts/make-icon.swift [repo root]
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        let s = size / 1024
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: srgb, components: [r, g, b, a])!
        }
        let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 186 * s, cornerHeight: 186 * s, transform: nil)

        // Drop shadow + graphite body.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: color(0, 0, 0, 0.35))
        ctx.addPath(tilePath); ctx.setFillColor(color(0.1, 0.1, 0.11)); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath); ctx.clip()
        let body = CGGradient(colorsSpace: srgb, colors: [color(0.21, 0.21, 0.23), color(0.08, 0.08, 0.09)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(body, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

        // A checklist: two lines that passed, one that did not.
        let rows: [(CGFloat, Bool)] = [(648, true), (480, true), (312, false)]
        for (y, passed) in rows {
            let accent = passed ? color(0.36, 0.92, 0.62) : color(1.0, 0.42, 0.36)
            let dot = CGRect(x: 236 * s, y: y * s, width: 104 * s, height: 104 * s)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 36 * s, color: passed ? color(0.25, 0.9, 0.55, 0.5) : color(1, 0.35, 0.3, 0.5))
            ctx.setFillColor(accent)
            ctx.fillEllipse(in: dot)
            ctx.restoreGState()

            ctx.setStrokeColor(color(0.06, 0.08, 0.07, 0.9)); ctx.setLineWidth(17 * s)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            if passed {
                ctx.move(to: CGPoint(x: 264 * s, y: (y + 52) * s))
                ctx.addLine(to: CGPoint(x: 281 * s, y: (y + 34) * s))
                ctx.addLine(to: CGPoint(x: 313 * s, y: (y + 70) * s))
            } else {
                ctx.move(to: CGPoint(x: 268 * s, y: (y + 72) * s)); ctx.addLine(to: CGPoint(x: 308 * s, y: (y + 32) * s))
                ctx.move(to: CGPoint(x: 308 * s, y: (y + 72) * s)); ctx.addLine(to: CGPoint(x: 268 * s, y: (y + 32) * s))
            }
            ctx.strokePath()

            let bar = CGRect(x: 392 * s, y: (y + 30) * s, width: (passed ? 396 : 280) * s, height: 44 * s)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 22 * s, cornerHeight: 22 * s, transform: nil))
            ctx.setFillColor(color(1, 1, 1, passed ? 0.2 : 0.42)); ctx.fillPath()
        }
        ctx.restoreGState()

        // Hairline edge highlight.
        ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5 * s, dy: 1.5 * s), cornerWidth: 184 * s, cornerHeight: 184 * s, transform: nil))
        ctx.setStrokeColor(color(1, 1, 1, 0.10)); ctx.setLineWidth(3 * s); ctx.strokePath()
        return true
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run(); task.waitUntilExit()
let docs = root.appendingPathComponent("docs")
try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: docs.appendingPathComponent("icon.png"))
try FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_256x256@2x.png"), to: docs.appendingPathComponent("icon.png"))
print("Wrote \(output.path)")
