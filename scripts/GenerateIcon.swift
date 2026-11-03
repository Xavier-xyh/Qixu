import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let body = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 204, yRadius: 204)
NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.20, blue: 0.36, alpha: 1), ending: NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.19, alpha: 1))!.draw(in: body, angle: -65)
// Three ordered strokes form an abstract canopy; the warm dot anchors the open corner.
let strokes: [(NSRect, NSColor)] = [
    (NSRect(x: 260, y: 605, width: 504, height: 122), NSColor(calibratedRed: 1.0, green: 0.67, blue: 0.43, alpha: 1)),
    (NSRect(x: 260, y: 441, width: 382, height: 122), NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.91, alpha: 1)),
    (NSRect(x: 260, y: 277, width: 260, height: 122), NSColor(calibratedRed: 0.71, green: 0.76, blue: 0.91, alpha: 1))
]
for (rect, color) in strokes {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 39, yRadius: 39).fill()
}
NSColor(calibratedRed: 1.0, green: 0.67, blue: 0.43, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 659, y: 295, width: 86, height: 86)).fill()
image.unlockFocus()
let source = NSBitmapImageRep(data: image.tiffRepresentation!)!.cgImage!
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        try data.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
