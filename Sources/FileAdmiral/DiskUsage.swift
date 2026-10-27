import AppKit

/// Size tree of a folder for the disk usage map. Small files are summed into one "other files" node per folder.
final class UsageNode {
    let name: String
    let url: URL
    let isDirectory: Bool
    var size: Int64 = 0
    var children: [UsageNode] = []
    weak var parent: UsageNode?
    /// Number of files summed into this node (for the "other files" bucket).
    var fileCount = 0

    init(name: String, url: URL, isDirectory: Bool) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
    }

    var isBucket: Bool { !isDirectory && fileCount > 1 }

    /// Scans a folder tree. Files smaller than 0.5% of their folder are summed into one node.
    static func scan(_ url: URL, hidden: Bool, cancel: CancelFlag, progress: ((Int) -> Void)? = nil) -> UsageNode {
        var counter = 0
        let rootDevice = volumeDevice(of: url)
        func walk(_ dir: URL, name: String) -> UsageNode {
            let node = UsageNode(name: name, url: dir, isDirectory: true)
            guard !cancel.isCancelled else { return node }
            var files: [UsageNode] = []
            for item in (try? FileItem.list(dir, showHidden: hidden)) ?? [] where !item.isSymlink {
                if cancel.isCancelled { break }
                if item.isDirectory {
                    // Other volumes and the firmlinked data volume would count the same bytes twice.
                    if item.url.path == dataVolumeFirmlink || (rootDevice != nil && item.device != rootDevice) { continue }
                    let child = walk(item.url, name: item.name)
                    child.parent = node
                    node.children.append(child)
                } else {
                    let f = UsageNode(name: item.name, url: item.url, isDirectory: false)
                    f.size = item.size
                    f.fileCount = 1
                    files.append(f)
                    counter += 1
                    if counter % 2000 == 0 { progress?(counter) }
                }
            }
            node.size = node.children.reduce(0) { $0 + $1.size } + files.reduce(0) { $0 + $1.size }
            let threshold = max(node.size / 200, 1)
            let (big, small) = (files.filter { $0.size >= threshold }, files.filter { $0.size < threshold })
            for f in big { f.parent = node }
            node.children += big
            if !small.isEmpty {
                let bucket = UsageNode(name: "\(small.count) smaller files", url: dir, isDirectory: false)
                bucket.size = small.reduce(0) { $0 + $1.size }
                bucket.fileCount = small.count
                bucket.parent = node
                node.children.append(bucket)
            }
            node.children.sort { $0.size > $1.size }
            return node
        }
        return walk(url, name: url.lastPathComponent)
    }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk).
enum Treemap {
    static func layout(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        guard !sizes.isEmpty, rect.width > 0, rect.height > 0 else { return sizes.map { _ in .zero } }
        let total = sizes.reduce(0, +)
        guard total > 0 else { return sizes.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = sizes.map { $0 * scale }
        var result = [CGRect](repeating: .zero, count: sizes.count)
        var remaining = rect
        var start = 0
        while start < areas.count {
            let short = Double(min(remaining.width, remaining.height))
            var end = start + 1
            func worst(_ s: Int, _ e: Int) -> Double {
                let row = areas[s..<e]
                let sum = row.reduce(0, +)
                guard let mx = row.max(), let mn = row.min(), sum > 0, mn > 0 else { return .infinity }
                return max(short * short * mx / (sum * sum), (sum * sum) / (short * short * mn))
            }
            while end < areas.count && worst(start, end + 1) <= worst(start, end) { end += 1 }
            let sum = areas[start..<end].reduce(0, +)
            let horizontal = remaining.width >= remaining.height
            let thickness = CGFloat(sum / short)
            var offset: CGFloat = 0
            for i in start..<end {
                let length = CGFloat(areas[i] / Double(thickness))
                result[i] = horizontal
                    ? CGRect(x: remaining.minX, y: remaining.maxY - offset - length, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                offset += length
            }
            if horizontal {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY, width: remaining.width - thickness,
                                   height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width,
                                   height: remaining.height - thickness)
            }
            start = end
        }
        return result
    }
}

/// Draws one level of the usage tree as a treemap.
final class TreemapView: NSView {
    var node: UsageNode? { didSet { relayout() } }
    var onOpenFolder: ((UsageNode) -> Void)?
    var onOpenFile: ((UsageNode) -> Void)?
    var onHover: ((UsageNode?) -> Void)?
    private var rects: [(CGRect, UsageNode)] = []
    private var hovered: UsageNode? { didSet { if hovered !== oldValue { needsDisplay = true; onHover?(hovered) } } }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        guard let node else { rects = []; needsDisplay = true; return }
        let kids = node.children.filter { $0.size > 0 }
        let frames = Treemap.layout(kids.map { Double($0.size) }, in: bounds.insetBy(dx: 2, dy: 2))
        rects = Array(zip(frames, kids))
        needsDisplay = true
    }

    static func color(for n: UsageNode) -> NSColor {
        if n.isDirectory { return .systemBlue }
        if n.isBucket { return .systemGray }
        switch (n.name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "tif", "tiff", "webp", "raw", "cr2", "nef", "psd", "svg", "avif": return .systemGreen
        case "mov", "mp4", "m4v", "mkv", "avi", "webm": return .systemPurple
        case "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg": return .systemOrange
        case "zip", "gz", "tgz", "xz", "bz2", "7z", "rar", "dmg", "iso", "pkg", "tar": return .systemBrown
        case "swift", "c", "h", "m", "cpp", "js", "ts", "py", "rb", "go", "rs", "java", "kt", "json", "xml", "html", "css":
            return .systemTeal
        case "pdf", "doc", "docx", "pages", "txt", "md", "rtf", "xls", "xlsx", "numbers", "key", "ppt", "pptx": return .systemPink
        default: return .systemIndigo
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        for (r, n) in rects where r.width >= 1 && r.height >= 1 {
            let base = Self.color(for: n)
            let fill = n === hovered ? base.blended(withFraction: 0.35, of: .white)! : base.blended(withFraction: 0.15, of: .black)!
            NSGradient(starting: fill.blended(withFraction: 0.25, of: .white)!, ending: fill)!.draw(in: r.insetBy(dx: 1, dy: 1), angle: -90)
            NSColor.black.withAlphaComponent(0.35).setStroke()
            NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            if r.width > 60 && r.height > 30 {
                let title = NSAttributedString(string: (n.isDirectory ? "📁 " : "") + n.name, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white,
                ])
                let size = NSAttributedString(string: Fmt.bytes(n.size), attributes: [
                    .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.85),
                ])
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: r.insetBy(dx: 3, dy: 3)).addClip()
                title.draw(at: NSPoint(x: r.minX + 5, y: r.maxY - 17))
                size.draw(at: NSPoint(x: r.minX + 5, y: r.maxY - 31))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private func node(at event: NSEvent) -> UsageNode? {
        let p = convert(event.locationInWindow, from: nil)
        return rects.first { $0.0.contains(p) }?.1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = node(at: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        guard let n = node(at: event) else { return }
        if n.isDirectory && !n.children.isEmpty {
            onOpenFolder?(n)
        } else if event.clickCount == 2 && !n.isBucket {
            onOpenFile?(n)
        }
    }
}

/// Commands → Disk Usage: treemap of what takes space in a folder.
final class DiskUsageWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: DiskUsageWindowController?
    private weak var controller: MainWindowController?
    private let map = TreemapView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton(title: "◀ Up", target: nil, action: nil)
    private var root: UsageNode?
    private var scanning: CancelFlag?

    static func show(controller: MainWindowController, folder: URL) {
        let c = shared ?? DiskUsageWindowController(controller: controller)
        shared = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.scan(folder)
    }

    private init(controller: MainWindowController) {
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Disk Usage"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.setFrameAutosaveName("DiskUsage")
        buildUI()
        w.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        backButton.target = self
        backButton.action = #selector(goUp(_:))
        backButton.isEnabled = false
        pathLabel.font = Theme.boldFont
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoLabel.font = Theme.smallFont
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [backButton, pathLabel])
        bar.spacing = 10
        map.onOpenFolder = { [weak self] n in self?.show(n) }
        map.onOpenFile = { [weak self] n in self?.controller?.goToFile(n.url) }
        map.onHover = { [weak self] n in
            guard let self, let current = self.map.node else { return }
            if let n {
                let pct = current.size > 0 ? Double(n.size) / Double(current.size) * 100 : 0
                self.infoLabel.stringValue = "\(n.isBucket ? n.name : n.url.abbreviatedPath)   \(Fmt.bytes(n.size))   "
                    + String(format: "%.1f%%", pct) + (n.isDirectory ? "   (click to open)" : "")
            } else {
                self.infoLabel.stringValue = "Click a folder to look inside, double-click a file to show it in the panel."
            }
        }
        for v in [bar, map, infoLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            map.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            map.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            map.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            infoLabel.topAnchor.constraint(equalTo: map.bottomAnchor, constant: 6),
            infoLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            infoLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            infoLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    func scan(_ folder: URL) {
        scanning?.cancel()
        let flag = CancelFlag()
        scanning = flag
        map.node = nil
        pathLabel.stringValue = folder.abbreviatedPath
        infoLabel.stringValue = "Scanning…"
        let hidden = controller?.showHidden ?? false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tree = UsageNode.scan(folder, hidden: hidden, cancel: flag) { n in
                DispatchQueue.main.async { self?.infoLabel.stringValue = "Scanning… \(Fmt.int(Int64(n))) files" }
            }
            DispatchQueue.main.async {
                guard let self, self.scanning === flag else { return }
                self.scanning = nil
                self.root = tree
                self.show(tree)
            }
        }
    }

    private func show(_ node: UsageNode) {
        map.node = node
        backButton.isEnabled = node.parent != nil
        pathLabel.stringValue = "\(node.url.abbreviatedPath)   —   \(Fmt.bytes(node.size))"
        infoLabel.stringValue = "Click a folder to look inside, double-click a file to show it in the panel."
    }

    @objc private func goUp(_ sender: Any?) {
        if let parent = map.node?.parent { show(parent) }
    }

    func windowWillClose(_ notification: Notification) { scanning?.cancel() }
}
