import AppKit

/// A folder in the tree; children are loaded when the node is first expanded.
final class FolderNode {
    let url: URL
    let name: String
    private var loaded: [FolderNode]?

    init(url: URL, name: String? = nil) {
        self.url = url
        self.name = name ?? (url.path == "/" ? "/" : url.lastPathComponent)
    }

    func children(showHidden: Bool) -> [FolderNode] {
        if let loaded { return loaded }
        let items = (try? FileItem.list(url, showHidden: showHidden)) ?? []
        let folders = items.filter { $0.isFolder && !$0.isSymlink }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { FolderNode(url: $0.url, name: $0.name) }
        loaded = folders
        return folders
    }

    func reset() { loaded = nil }
}

/// Outline view of folders (TC Ctrl+F8). Enter opens the folder in the panel, Esc returns.
final class FolderTreeView: NSOutlineView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var panel: FilePanel?
    private var root: FolderNode?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let col = NSTableColumn(identifier: .init("folder"))
        col.title = "Folders"
        addTableColumn(col)
        outlineTableColumn = col
        headerView = nil
        dataSource = self
        delegate = self
        rowHeight = Theme.rowHeight
        style = .plain
        focusRingType = .none
        target = self
        doubleAction = #selector(openSelected(_:))
        autoresizesOutlineColumn = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private var showHidden: Bool { panel?.controller?.showHidden ?? false }

    /// Shows the tree of the volume containing `url`, expanded down to `url`.
    func show(_ shown: URL) {
        // Follow links (/tmp → /private/tmp): the tree only contains real folders. realpath() is used because
        // Foundation's resolvingSymlinksInPath strips the "/private" prefix again.
        let url = FolderTreeView.realURL(shown)
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? URL(fileURLWithPath: "/")
        let rootURL = volume.path == "/" || !url.path.hasPrefix(volume.path) ? URL(fileURLWithPath: "/") : volume
        root = FolderNode(url: rootURL, name: rootURL.path == "/" ? "/" : rootURL.lastPathComponent)
        reloadData()
        expandItem(root)
        // Walk down the path, expanding each folder.
        var node = root
        let rel = url.path.dropFirst(rootURL.path == "/" ? 1 : rootURL.path.count + 1)
        for comp in rel.split(separator: "/") {
            guard let n = node, let child = n.children(showHidden: showHidden).first(where: { $0.name == comp }) else { break }
            expandItem(n)
            node = child
        }
        let row = self.row(forItem: node)
        if row >= 0 {
            selectRowIndexes([row], byExtendingSelection: false)
            scrollRowToVisible(row)
        }
    }

    static func realURL(_ url: URL) -> URL {
        guard let r = realpath(url.path, nil) else { return url }
        defer { free(r) }
        return URL(fileURLWithPath: String(cString: r))
    }

    var selectedFolder: URL? { (item(atRow: selectedRow) as? FolderNode)?.url }

    @objc func openSelected(_ sender: Any?) {
        guard let url = selectedFolder else { return }
        panel?.leaveTree(openingFolder: url)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: openSelected(nil) // Enter
        case 53: panel?.leaveTree(openingFolder: nil) // Esc
        case 48: panel?.controller?.switchPanel() // Tab
        default:
            if event.modifierFlags.contains(.control), event.keyCode == 100 { // ⌃F8 toggles back
                panel?.leaveTree(openingFolder: nil)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { panel?.didBecomeActive() }
        return ok
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FolderNode else { return root == nil ? 0 : 1 }
        return node.children(showHidden: showHidden).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FolderNode else { return root! }
        return node.children(showHidden: showHidden)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        // Assume folders have subfolders until expanded (listing every folder up front would be slow).
        true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: .init("folderCell"), owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = .init("folderCell")
            let iv = NSImageView()
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            for v in [iv, tf] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(v)
            }
            c.imageView = iv
            c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = node.name
        cell.textField?.font = Theme.font
        cell.textField?.textColor = Theme.current.folderText
        let icon = node.url.path == "/" ? NSWorkspace.shared.icon(forFile: "/") : NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { FileRowView() }
}
