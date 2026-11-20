// Renders App/LocalFlow/AppIcon.icns: a violet squircle with white voice bars.
import AppKit
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let set = out.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    let shadow = NSShadow(); shadow.shadowBlurRadius = s * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.set()
    NSGradient(colors: [NSColor(red: 0.55, green: 0.42, blue: 1.0, alpha: 1), NSColor(red: 0.27, green: 0.22, blue: 0.82, alpha: 1)])!
        .draw(in: shape, angle: -70)
    NSShadow().set()
    shape.addClip()
    NSColor.white.withAlphaComponent(0.08).setFill()
    NSBezierPath(ovalIn: NSRect(x: r.minX - r.width * 0.2, y: r.midY, width: r.width * 1.4, height: r.height * 0.9)).fill()
    let heights: [CGFloat] = [0.18, 0.36, 0.56, 0.36, 0.24]
    let w = r.width * 0.075, gap = r.width * 0.055
    let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
    NSColor.white.setFill()
    for (i, h) in heights.enumerated() {
        let bh = r.height * h
        let x = r.midX - total / 2 + CGFloat(i) * (w + gap)
        NSBezierPath(roundedRect: NSRect(x: x, y: r.midY - bh / 2, width: w, height: bh), xRadius: w / 2, yRadius: w / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
