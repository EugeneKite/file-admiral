import AppKit
import Quartz
import QuickLookThumbnailing

/// Thumbnail cache backed by Quick Look (images, PDFs, videos, documents…).
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 2000
        // Bounded in bytes too: 2000 "Huge" thumbnails at 2x would be over 2 GB.
        cache.totalCostLimit = 256 << 20
    }

    private func key(_ item: FileItem, _ size: CGFloat) -> NSString {
        "\(item.url.path)|\(item.modified.timeIntervalSince1970)|\(Int(size))" as NSString
    }

    func cached(_ item: FileItem, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(item, size))
    }

    /// Generates a thumbnail; `completion` runs on the main thread (only if a thumbnail was produced).
    func request(_ item: FileItem, size: CGFloat, scale: CGFloat, completion: @escaping (NSImage) -> Void) {
        guard item.url.isFileURL, !item.isParent else { return }
        let k = key(item, size)
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size), scale: scale,
                                                   representationTypes: [.thumbnail, .icon])
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep, let image = Optional(rep.nsImage) else { return }
            let cost = rep.cgImage.width * rep.cgImage.height * 4
            DispatchQueue.main.async {
                self?.cache.setObject(image, forKey: k, cost: cost)
                completion(image)
            }
        }
    }
}

/// One tile of the thumbnail grid.
final class ThumbnailItemView: NSView {
    let imageView = NSImageView()
    let label = NSTextField(wrappingLabelWithString: "")
    var isCursor = false { didSet { needsDisplay = true; updateColors() } }
    var isEmphasized = false { didSet { needsDisplay = true; updateColors() } }
    var isMarked = false { didSet { needsDisplay = true; updateColors() } }
    var isDim = false { didSet { updateColors() } }
    var representedPath = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        addSubview(label)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            imageView.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func updateColors() {
        let t = Theme.current
        label.font = .systemFont(ofSize: max(Theme.fontSize - 1, 10))
        if isMarked {
            label.textColor = isCursor && isEmphasized ? t.markedOnCursor : t.marked
        } else if isCursor && isEmphasized {
            label.textColor = t.cursorText
        } else {
            label.textColor = isDim ? t.hiddenText : t.text
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = Theme.current
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        if isCursor {
            (isEmphasized ? t.cursor : t.cursorInactive).setFill()
            path.fill()
        }
        if isMarked {
            t.marked.setStroke()
            path.lineWidth = 2.5
            path.stroke()
        }
    }
}

final class ThumbnailItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("ThumbnailItem")
    override func loadView() { view = ThumbnailItemView(frame: .zero) }
    var tile: ThumbnailItemView { view as! ThumbnailItemView }
}

/// Grid of thumbnails shown instead of the file list in thumbnail mode.
/// The panel's (hidden) table stays the source of truth for the cursor; this view mirrors it.
final class ThumbnailGridView: NSCollectionView, QLPreviewPanelDataSource {
    weak var panel: FilePanel?

    /// Number of tiles per row.
    var columns: Int {
        guard let layout = collectionViewLayout as? NSCollectionViewFlowLayout else { return 1 }
        let w = layout.itemSize.width + layout.minimumInteritemSpacing
        return max(1, Int((bounds.width - layout.sectionInset.left - layout.sectionInset.right + layout.minimumInteritemSpacing) / w))
    }

    override func keyDown(with event: NSEvent) {
        guard let panel else { return super.keyDown(with: event) }
        if panel.handleKey(event) { return }
        let shift = event.modifierFlags.contains(.shift)
        let delta: Int
        switch event.keyCode {
        case 123: delta = -1
        case 124: delta = 1
        case 125: delta = columns
        case 126: delta = -columns
        default:
            super.keyDown(with: event)
            return
        }
        panel.moveCursorBy(delta, mark: shift)
    }

    private func index(at event: NSEvent) -> Int? {
        indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let panel, let i = index(at: event) else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            panel.toggleMark(row: i)
            panel.setCursor(i)
        } else if mods.contains(.shift) {
            panel.markRange(from: panel.tableView.selectedRow, to: i)
            panel.setCursor(i)
        } else {
            panel.setCursor(i)
            if event.clickCount == 2 {
                panel.openCursor()
                return
            }
            // Let NSCollectionView start a drag if the mouse moves.
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        guard let panel, let i = index(at: event) else { return nil }
        panel.setCursor(i)
        return panel.contextMenu()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            panel?.didBecomeActive()
            panel?.refreshThumbnailEmphasis()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { DispatchQueue.main.async { self.panel?.refreshThumbnailEmphasis() } }
        return ok
    }

    override func selectAll(_ sender: Any?) { panel?.markAll(true) }
    @objc func copy(_ sender: Any?) { panel?.copyToPasteboard() }
    @objc func paste(_ sender: Any?) { panel?.pasteFromPasteboard() }

    // MARK: Quick Look (⌘Y) works in thumbnail mode too

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { self.panel?.previewURLs.count ?? 0 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let urls = self.panel?.previewURLs, index < urls.count else { return nil }
        return urls[index] as NSURL
    }
}
