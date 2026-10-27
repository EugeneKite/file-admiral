// Renders the Admiral app icon (navy tile, two file panels, gold admiral's sleeve stripes and star)
// into an .iconset folder.
// Usage: swift Tools/MakeIcon.swift <output.iconset> [preview.png]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func star(center: NSPoint, outer: CGFloat, inner: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    for i in 0..<10 {
        let r = i % 2 == 0 ? outer : inner
        let a = CGFloat.pi / 2 + CGFloat(i) * .pi / 5
        let pt = NSPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
        if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
    }
    p.close()
    return p
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let u = s / 1024 // design units: 1024 grid

    // Tile (macOS icon grid: 824 x 824 body, corner radius ~185)
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tile = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * u
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
    shadow.set()
    rgb(13, 42, 92).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: rgb(28, 74, 140), ending: rgb(9, 30, 68))!.draw(in: tile, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    // Two file panels
    let panelTop: CGFloat = 820, panelBottom: CGFloat = 395
    let gap: CGFloat = 26, margin: CGFloat = 176
    let panelW = (1024 - 2 * margin - gap) / 2
    for i in 0..<2 {
        let x = margin + CGFloat(i) * (panelW + gap)
        let r = NSRect(x: x * u, y: panelBottom * u, width: panelW * u, height: (panelTop - panelBottom) * u)
        let path = NSBezierPath(roundedRect: r, xRadius: 26 * u, yRadius: 26 * u)
        NSGraphicsContext.saveGraphicsState()
        let ps = NSShadow()
        ps.shadowColor = NSColor.black.withAlphaComponent(0.3)
        ps.shadowBlurRadius = 14 * u
        ps.shadowOffset = NSSize(width: 0, height: -6 * u)
        ps.set()
        rgb(246, 248, 252).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // header bar (left panel active)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        (i == 0 ? rgb(47, 125, 225) : rgb(196, 203, 214)).setFill()
        NSRect(x: r.minX, y: r.maxY - 58 * u, width: r.width, height: 58 * u).fill()
        NSGraphicsContext.restoreGraphicsState()

        // file rows
        let rowH: CGFloat = 46
        for row in 0..<6 {
            let y = panelTop - 58 - 30 - CGFloat(row) * rowH
            guard y - 18 > panelBottom + 16 else { break }
            let isCursor = i == 0 && row == 2
            let isMarked = i == 1 && (row == 1 || row == 3)
            if isCursor {
                rgb(47, 125, 225, 0.22).setFill()
                NSRect(x: r.minX, y: (y - 30) * u, width: r.width, height: rowH * u).fill()
            }
            let color: NSColor = isMarked ? rgb(215, 38, 38) : rgb(90, 104, 124)
            color.setFill()
            let w = panelW * (row % 3 == 0 ? 0.68 : (row % 3 == 1 ? 0.52 : 0.6))
            NSBezierPath(roundedRect: NSRect(x: (x + 26) * u, y: (y - 16) * u, width: w * u, height: 15 * u),
                         xRadius: 7 * u, yRadius: 7 * u).fill()
        }
    }

    // Gold admiral's sleeve stripes: one broad band and one narrow band above it
    let gold = NSGradient(colors: [rgb(255, 226, 132), rgb(238, 186, 52), rgb(196, 140, 24)])!
    let broad = NSRect(x: body.minX, y: 190 * u, width: body.width, height: 92 * u)
    let narrow = NSRect(x: body.minX, y: 308 * u, width: body.width, height: 30 * u)
    gold.draw(in: broad, angle: -90)
    gold.draw(in: narrow, angle: -90)
    rgb(150, 100, 10, 0.5).setFill()
    NSRect(x: broad.minX, y: broad.minY, width: broad.width, height: 3 * u).fill()
    NSRect(x: narrow.minX, y: narrow.minY, width: narrow.width, height: 2 * u).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Gold star on the broad stripe's center, over the panels' bottom edge
    let starPath = star(center: NSPoint(x: 512 * u, y: 236 * u), outer: 74 * u, inner: 30 * u)
    NSGraphicsContext.saveGraphicsState()
    let ss = NSShadow()
    ss.shadowColor = NSColor.black.withAlphaComponent(0.35)
    ss.shadowBlurRadius = 8 * u
    ss.shadowOffset = NSSize(width: 0, height: -3 * u)
    ss.set()
    rgb(13, 42, 92).setFill()
    starPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: rgb(40, 92, 170), ending: rgb(10, 34, 78))!.draw(in: starPath, angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
if args.count > 2 {
    try! render(1024).write(to: URL(fileURLWithPath: args[2]))
}
