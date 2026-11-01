import AppKit

// Original vector mark: a tidy menu bar, two organized rows and an AI sparkle.
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}
let tile = rounded(NSRect(x: 54, y: 54, width: 916, height: 916), 210)
NSGradient(colors: [NSColor(srgbRed: 0.055, green: 0.12, blue: 0.24, alpha: 1),
                    NSColor(srgbRed: 0.10, green: 0.25, blue: 0.43, alpha: 1)])!.draw(in: tile, angle: 65)
NSGraphicsContext.saveGraphicsState()
tile.addClip()
let glow = NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.83, blue: 0.86, alpha: 0.34), ending: .clear)!
glow.draw(fromCenter: NSPoint(x: 760, y: 830), radius: 10, toCenter: NSPoint(x: 760, y: 830), radius: 680, options: .drawsBeforeStartingLocation)
NSGraphicsContext.restoreGraphicsState()
NSColor.white.withAlphaComponent(0.14).setStroke(); tile.lineWidth = 3; tile.stroke()

let bar = rounded(NSRect(x: 190, y: 590, width: 570, height: 140), 48)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
shadow.shadowBlurRadius = 35; shadow.shadowOffset = NSSize(width: 0, height: -18); shadow.set()
NSGradient(starting: .white, ending: NSColor(srgbRed: 0.73, green: 0.96, blue: 1, alpha: 1))!.draw(in: bar, angle: -90)
NSGraphicsContext.restoreGraphicsState()
NSColor(srgbRed: 0.075, green: 0.27, blue: 0.4, alpha: 1).setFill()
for x in [CGFloat(228), 290, 352] { rounded(NSRect(x: x, y: 639, width: 31, height: 42), 13).fill() }
rounded(NSRect(x: 540, y: 641, width: 158, height: 38), 19).fill()

let rowGradient = NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.84, blue: 0.89, alpha: 1), ending: NSColor(srgbRed: 0.48, green: 0.97, blue: 0.85, alpha: 1))!
rowGradient.draw(in: rounded(NSRect(x: 190, y: 406, width: 570, height: 103), 37), angle: 0)
NSColor.white.withAlphaComponent(0.93).setFill()
rounded(NSRect(x: 190, y: 250, width: 383, height: 87), 34).fill()
NSColor.white.withAlphaComponent(0.24).setFill()
rounded(NSRect(x: 621, y: 250, width: 139, height: 87), 34).fill()

let star = NSBezierPath()
star.move(to: NSPoint(x: 784, y: 841))
star.curve(to: NSPoint(x: 881, y: 744), controlPoint1: NSPoint(x: 804, y: 771), controlPoint2: NSPoint(x: 811, y: 764))
star.curve(to: NSPoint(x: 784, y: 647), controlPoint1: NSPoint(x: 811, y: 724), controlPoint2: NSPoint(x: 804, y: 717))
star.curve(to: NSPoint(x: 687, y: 744), controlPoint1: NSPoint(x: 764, y: 717), controlPoint2: NSPoint(x: 757, y: 724))
star.curve(to: NSPoint(x: 784, y: 841), controlPoint1: NSPoint(x: 757, y: 764), controlPoint2: NSPoint(x: 764, y: 771))
star.close()
NSColor(srgbRed: 0.68, green: 1, blue: 0.89, alpha: 1).setFill(); star.fill()
image.unlockFocus()

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = url.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
