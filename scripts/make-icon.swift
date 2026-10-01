import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let chassis = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 188, yRadius: 188)
        NSColor(calibratedRed: 0.47, green: 0.31, blue: 0.21, alpha: 1).setFill()
        chassis.fill()
        let face = NSBezierPath(roundedRect: NSRect(x: 131, y: 95, width: 762, height: 834), xRadius: 132, yRadius: 132)
        NSColor(calibratedRed: 0.92, green: 0.89, blue: 0.82, alpha: 1).setFill()
        face.fill()
        NSColor(calibratedRed: 0.21, green: 0.24, blue: 0.21, alpha: 1).setFill()
        let knob = NSBezierPath(ovalIn: NSRect(x: 337, y: 224, width: 350, height: 350))
        knob.fill()
        NSColor(calibratedRed: 0.98, green: 0.95, blue: 0.86, alpha: 1).setStroke()
        let tick = NSBezierPath()
        tick.lineWidth = 19; tick.lineCapStyle = .round
        tick.move(to: NSPoint(x: 546, y: 445)); tick.line(to: NSPoint(x: 603, y: 505)); tick.stroke()
        NSColor(calibratedRed: 0.70, green: 0.35, blue: 0.18, alpha: 1).setStroke()
        let wave = NSBezierPath()
        wave.lineWidth = 18; wave.lineCapStyle = .round
        for i in 0...160 {
            let t = Double(i) / 160
            let point = NSPoint(x: 222 + t * 580, y: 709 + sin(t * .pi * 4) * 55)
            if i == 0 { wave.move(to: point) } else { wave.line(to: point) }
        }
        wave.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
