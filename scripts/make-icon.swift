// Draws the Ponte app icon (a bridge over water) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <out.iconset>; then iconutil -c icns.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Squircle background (macOS grid: 824 pt body, 100 pt margin).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.05, green: 0.62, blue: 0.60, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.11, green: 0.24, blue: 0.56, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 864, y: 100), options: [])

    // Water.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    ctx.setLineWidth(18)
    ctx.setLineCap(.round)
    for (i, y) in [300.0, 240.0].enumerated() {
        let path = CGMutablePath()
        let inset = 230.0 + Double(i) * 70
        path.move(to: CGPoint(x: inset, y: y))
        var x = inset
        while x < 1024 - inset - 1 {
            path.addQuadCurve(to: CGPoint(x: x + 70, y: y), control: CGPoint(x: x + 35, y: y + 22))
            x += 70
        }
        ctx.addPath(path)
        ctx.strokePath()
    }

    // Bridge: arch, deck, hangers.
    ctx.setStrokeColor(NSColor.white.cgColor)
    let arch = CGMutablePath()
    arch.move(to: CGPoint(x: 250, y: 420))
    arch.addQuadCurve(to: CGPoint(x: 774, y: 420), control: CGPoint(x: 512, y: 840))
    ctx.setLineWidth(52)
    ctx.addPath(arch)
    ctx.strokePath()

    ctx.setLineWidth(40)
    ctx.move(to: CGPoint(x: 200, y: 420))
    ctx.addLine(to: CGPoint(x: 824, y: 420))
    ctx.strokePath()

    ctx.setLineWidth(18)
    for x in stride(from: 352.0, through: 672.0, by: 80.0) {
        let t = (x - 250) / 524
        let top = 420 + 2 * t * (1 - t) * 420 - 20
        ctx.move(to: CGPoint(x: x, y: 440))
        ctx.addLine(to: CGPoint(x: x, y: top))
        ctx.strokePath()
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print(out.path)
