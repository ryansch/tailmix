// Renders the tailmix app icon as a 1024x1024 PNG.
//
//   swift scripts/make-icon.swift out.png
//
// The icon is the tailmix.net "Braided Paths" mark (its favicon.svg): three
// strands that weave past one another on midnight navy, placed in the
// rounded square of Apple's macOS icon grid.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let navy = color(0x101936)
/// Each strand as in the SVG: a cubic curve in a 1024 square with y down,
/// in drawing order, so seafoam passes over coral and under gold.
let strands: [(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint, color: CGColor)] = [
    (CGPoint(x: -96, y: 512), CGPoint(x: 260, y: 512), CGPoint(x: 764, y: 288), CGPoint(x: 1120, y: 288), color(0xFF6B61)),
    (CGPoint(x: -96, y: 288), CGPoint(x: 280, y: 288), CGPoint(x: 744, y: 736), CGPoint(x: 1120, y: 736), color(0x32D6BA)),
    (CGPoint(x: -96, y: 736), CGPoint(x: 260, y: 736), CGPoint(x: 764, y: 512), CGPoint(x: 1120, y: 512), color(0xFFC857)),
]

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext

// The rounded square on Apple's macOS icon grid: 824 wide with a 100 margin,
// casting a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
context.addPath(tilePath)
context.setFillColor(navy)
context.fillPath()
context.restoreGState()

context.addPath(tilePath)
context.clip()
// Map the SVG's 1024 square, y down, onto the tile, y up.
context.translateBy(x: tile.minX, y: tile.maxY)
context.scaleBy(x: tile.width / 1024, y: -tile.height / 1024)
context.setLineCap(.round)
for strand in strands {
    // A wider navy stroke first leaves a gap where this strand crosses
    // the ones drawn before it.
    for (strokeColor, width) in [(navy, 176.0), (strand.color, 120.0)] {
        context.move(to: strand.start)
        context.addCurve(to: strand.end, control1: strand.control1, control2: strand.control2)
        context.setStrokeColor(strokeColor)
        context.setLineWidth(width)
        context.strokePath()
    }
}

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
