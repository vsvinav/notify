import AppKit
import ImageIO

guard CommandLine.arguments.count == 2 else { fatalError("Pass an output .iconset directory") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let side = CGFloat(pixels)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create app icon bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let tile = NSRect(x: side * 0.08, y: side * 0.08, width: side * 0.84, height: side * 0.84)
        NSColor(srgbRed: 0.13, green: 0.17, blue: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: tile, xRadius: side * 0.19, yRadius: side * 0.19).fill()
        NSColor(srgbRed: 0.75, green: 0.84, blue: 0.64, alpha: 1).setFill()
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: side * 0.57, y: side * 0.81))
        for (x, y) in [(0.29, 0.44), (0.47, 0.44), (0.42, 0.19), (0.73, 0.57), (0.54, 0.57)] {
            bolt.line(to: NSPoint(x: side * x, y: side * y))
        }
        bolt.close()
        bolt.fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let image = bitmap.cgImage,
              let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)
        else { fatalError("Cannot encode app icon") }
        let origin = "Original procedural AppKit artwork authored for Notify in scripts/generate-icon.swift. No sourced or image-generated artwork."
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: origin]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write app icon") }
    }
}
