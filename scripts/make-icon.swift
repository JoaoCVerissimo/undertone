// Renders Undertone's app icon (a waveform on a blue→violet gradient) and packs it into an .icns.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1])

func render(pixels: Double) -> Data {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size, flipped: false) { rect in
        // macOS icons leave breathing room around the rounded square.
        let inset = rect.insetBy(dx: pixels * 0.075, dy: pixels * 0.075)
        let radius = inset.width * 0.225
        let shape = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = pixels * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -pixels * 0.01)
        shadow.set()
        NSColor(srgbRed: 0.25, green: 0.47, blue: 0.92, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.30, green: 0.58, blue: 0.97, alpha: 1),
            NSColor(srgbRed: 0.24, green: 0.42, blue: 0.90, alpha: 1),
            NSColor(srgbRed: 0.45, green: 0.30, blue: 0.86, alpha: 1),
        ])!
        gradient.draw(in: shape, angle: -65)

        // Soft highlight across the top for a glassy feel.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0.0)])!
        highlight.draw(in: NSRect(x: inset.minX, y: inset.midY, width: inset.width, height: inset.height / 2), angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        // The waveform, drawn in white.
        let config = NSImage.SymbolConfiguration(pointSize: pixels * 0.40, weight: .medium)
        if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let tinted = NSImage(size: symbol.size, flipped: false) { symbolRect in
                symbol.draw(in: symbolRect)
                NSColor.white.set()
                symbolRect.fill(using: .sourceAtop)
                return true
            }
            let origin = NSPoint(x: rect.midX - tinted.size.width / 2, y: rect.midY - tinted.size.height / 2)
            tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }
        return true
    }
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Undertone-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(pixels: Double(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: Double(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(output.path)")
