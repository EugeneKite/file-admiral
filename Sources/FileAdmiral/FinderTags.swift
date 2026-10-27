import AppKit
import Darwin

/// A Finder tag: name plus Finder's color index (0 none, 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange).
struct FinderTag: Hashable {
    let name: String
    let colorIndex: Int

    var color: NSColor? { FinderTags.color(colorIndex) }
}

/// Reads and writes real Finder tags, so tags are shared with Finder and Spotlight.
enum FinderTags {
    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    static func color(_ index: Int) -> NSColor? {
        switch index {
        case 1: return .systemGray
        case 2: return .systemGreen
        case 3: return .systemPurple
        case 4: return .systemBlue
        case 5: return .systemYellow
        case 6: return .systemRed
        case 7: return .systemOrange
        default: return nil
        }
    }

    /// The seven color tags with their (localized) Finder names, in Finder's menu order.
    static var standard: [FinderTag] {
        let names = NSWorkspace.shared.fileLabels // index 0 is "None"
        return [6, 7, 5, 2, 4, 3, 1].map { i in
            FinderTag(name: i < names.count ? names[i] : ["", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"][i],
                      colorIndex: i)
        }
    }

    /// Reads the tags straight from the extended attribute (fast, includes colors).
    static func read(_ path: String) -> [FinderTag] {
        let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read > 0,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        let standardByName = Dictionary(standard.map { ($0.name, $0.colorIndex) }, uniquingKeysWith: { a, _ in a })
        return list.map { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1).map(String.init)
            let name = parts.first ?? entry
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : standardByName[name] ?? 0
            return FinderTag(name: name, colorIndex: index)
        }
    }

    /// Sets the tags of a file (by name; Finder assigns the colors of known tags).
    static func write(_ url: URL, _ tags: [FinderTag]) throws {
        try (url as NSURL).setResourceValue(tags.map(\.name), forKey: .tagNamesKey)
    }

    /// Adds `tag` to every item, or removes it from all when every item already has it.
    static func toggle(_ tag: FinderTag, on urls: [URL]) throws {
        let current = urls.map { read($0.path) }
        let allHave = current.allSatisfy { $0.contains { $0.name == tag.name } }
        for (url, tags) in zip(urls, current) {
            var names = tags.filter { $0.name != tag.name }
            if !allHave { names.append(tag) }
            try write(url, names)
        }
    }

    /// Small colored circle used in menus.
    static func dot(_ color: NSColor?, size: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let path = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            if let color {
                color.setFill()
                path.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            return true
        }
    }
}

/// Overlapping colored dots, like Finder shows after a file name.
final class TagDotsView: NSView {
    var colors: [NSColor] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: colors.isEmpty ? 0 : CGFloat(colors.count - 1) * 6 + 11, height: 11)
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = (bounds.height - 10) / 2
        for (i, c) in colors.enumerated().reversed() {
            let r = NSRect(x: CGFloat(i) * 6, y: y, width: 10, height: 10)
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: -1, dy: -1)).fill()
            c.setFill()
            NSBezierPath(ovalIn: r).fill()
        }
    }
}
