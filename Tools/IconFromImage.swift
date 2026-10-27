// Turns a square app-icon artwork (rounded tile, possibly with soft or noisy edges) into a macOS
// .iconset: finds the tile, trims it with a clean rounded-rect mask and places it on the standard
// macOS icon grid (824/1024 body) with a drop shadow.
// Usage: swift Tools/IconFromImage.swift <artwork.png> <output.iconset> [preview.png]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1]))),
      let source = rep.cgImage else {
    print("usage: IconFromImage <artwork.png> <output.iconset> [preview.png]")
    exit(1)
}
let out = args[2]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// Find the tile: rows/columns where most pixels are opaque (ignores stray specks around it).
let w = rep.pixelsWide, h = rep.pixelsHigh
func opaque(_ x: Int, _ y: Int) -> Bool { (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9 }
func extent(count: Int, length: Int, line: (Int) -> (Int) -> Bool) -> (Int, Int) {
    var first = 0, last = count - 1
    let needed = length * 2 / 5
    func full(_ i: Int) -> Bool {
        var n = 0
        let f = line(i)
        for j in stride(from: 0, to: length, by: 2) where f(j) { n += 2 }
        return n >= needed
    }
    while first < count && !full(first) { first += 1 }
    while last > first && !full(last) { last -= 1 }
    return (first, last)
}
let (top, bottom) = extent(count: h, length: w) { y in { x in opaque(x, y) } }
let (left, right) = extent(count: w, length: h) { x in { y in opaque(x, y) } }
let inset = 4
// Square crop centered on the tile, so the artwork is never stretched.
let side = min(right - left, bottom - top) - 2 * inset
let crop = CGRect(x: (left + right - side) / 2, y: (top + bottom - side) / 2, width: side, height: side)
let tile = source.cropping(to: crop)!
print("tile found at \(crop)")

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
    NSGraphicsContext.current?.imageInterpolation = .high
    let u = s / 1024
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let mask = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)

    // Shadow under the tile
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = 22 * u
    shadow.shadowOffset = NSSize(width: 0, height: -9 * u)
    shadow.set()
    NSColor(srgbRed: 0.06, green: 0.25, blue: 0.7, alpha: 1).setFill()
    mask.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    mask.addClip()
    NSImage(cgImage: tile, size: NSSize(width: tile.width, height: tile.height)).draw(in: body)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return r.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
if args.count > 3 { try! render(1024).write(to: URL(fileURLWithPath: args[3])) }
