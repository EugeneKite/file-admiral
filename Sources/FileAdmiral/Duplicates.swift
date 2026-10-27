import AppKit
import CryptoKit

/// Finds files with identical content: same size, then same hash of the first 64 KB, then same full SHA-256.
enum DuplicateFinder {
    struct Group {
        let size: Int64
        var files: [FileItem] // oldest first
    }

    static func find(in root: URL, subfolders: Bool, hidden: Bool, minSize: Int64, cancel: CancelFlag,
                     progress: ((String) -> Void)? = nil) -> [Group] {
        var bySize: [Int64: [FileItem]] = [:]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !hidden { options.insert(.skipsHiddenFiles) }
        if !subfolders { options.insert(.skipsSubdirectoryDescendants) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options,
                                                errorHandler: { _, _ in true })
        // Stay on the start volume and out of the firmlinked data volume: the same file reached by two
        // paths is not a duplicate, and trashing "one of them" would delete the only copy.
        let rootDevice = volumeDevice(of: root)
        var scanned = 0
        while let u = en?.nextObject() as? URL {
            if cancel.isCancelled { return [] }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if u.path == dataVolumeFirmlink || (rootDevice != nil && volumeDevice(of: u) != rootDevice) {
                    en?.skipDescendants()
                }
                continue
            }
            guard let item = FileItem.make(u), !item.isDirectory, !item.isSymlink, item.size >= minSize else { continue }
            bySize[item.size, default: []].append(item)
            scanned += 1
            if scanned % 500 == 0 { progress?("Scanned \(Fmt.int(Int64(scanned))) files…") }
        }
        var groups: [Group] = []
        let candidates = bySize.filter { $0.value.count > 1 }
        var checked = 0
        for (size, allFiles) in candidates.sorted(by: { $0.key > $1.key }) {
            if cancel.isCancelled { return [] }
            // Hard links and firmlink aliases share an inode: one entry per physical file.
            var seen = Set<String>()
            let files = allFiles.filter { seen.insert("\($0.device):\($0.inode)").inserted }
            guard files.count > 1 else { continue }
            // Cheap first pass on the first 64 KB, full hash only for files that still collide.
            for partial in Dictionary(grouping: files, by: { hash($0.url, limit: 64 << 10) }).values where partial.count > 1 {
                for full in Dictionary(grouping: partial, by: { hash($0.url, limit: nil) }).values where full.count > 1 {
                    groups.append(Group(size: size, files: full.sorted { $0.modified < $1.modified }))
                }
            }
            checked += files.count
            progress?("Comparing contents… \(Fmt.int(Int64(checked))) files")
        }
        return groups.sorted { $0.size * Int64($0.files.count - 1) > $1.size * Int64($1.files.count - 1) }
    }

    /// SHA-256 of the first `limit` bytes (or the whole file).
    static func hash(_ url: URL, limit: Int?) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "unreadable:\(url.path)" }
        defer { try? h.close() }
        var sha = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            guard let chunk = try? h.read(upToCount: min(1 << 20, remaining)), !chunk.isEmpty else { break }
            sha.update(data: chunk)
            remaining -= chunk.count
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Commands → Find Duplicates.
final class DuplicatesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var shared: DuplicatesWindowController?
    private weak var controller: MainWindowController?

    private enum Row {
        case group(Int)
        case file(Int, Int)
    }

    private let folderField = NSTextField()
    private let subfoldersCheck = NSButton(checkboxWithTitle: "Subfolders", target: nil, action: nil)
    private let hiddenCheck = NSButton(checkboxWithTitle: "Hidden files", target: nil, action: nil)
    private let minSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let startButton = NSButton(title: "Find Duplicates", target: nil, action: nil)
    private let trashButton = NSButton(title: "Move Checked to Trash", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private var groups: [DuplicateFinder.Group] = []
    private var rows: [Row] = []
    private var checked = Set<String>() // paths to delete
    private var running: CancelFlag?
    private static let minSizes: [(String, Int64)] = [("Any size", 1), ("≥ 100 KB", 100 << 10), ("≥ 1 MB", 1 << 20),
                                                       ("≥ 10 MB", 10 << 20), ("≥ 100 MB", 100 << 20)]

    static func show(controller: MainWindowController, folder: URL) {
        let c = shared ?? DuplicatesWindowController(controller: controller)
        shared = c
        if c.running == nil { c.folderField.stringValue = folder.path }
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private init(controller: MainWindowController) {
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Find Duplicates"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.setFrameAutosaveName("FindDuplicates")
        buildUI()
        w.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        subfoldersCheck.state = .on
        minSizePopup.addItems(withTitles: Self.minSizes.map(\.0))
        minSizePopup.selectItem(at: 1)
        startButton.target = self
        startButton.action = #selector(start(_:))
        startButton.keyEquivalent = "\r"
        trashButton.target = self
        trashButton.action = #selector(trashChecked(_:))
        trashButton.isEnabled = false
        statusLabel.font = Theme.smallFont
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderField.widthAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true
        let top = NSStackView(views: [NSTextField(labelWithString: "Folder:"), folderField])
        let options = NSStackView(views: [subfoldersCheck, hiddenCheck, minSizePopup, startButton, trashButton, statusLabel])
        options.spacing = 12

        for (id, title, width) in [("check", "", 28.0), ("name", "File", 300.0), ("folder", "Folder", 380.0), ("date", "Modified", 140.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = CGFloat(width)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Theme.rowHeight + 2
        table.style = .plain
        table.target = self
        table.doubleAction = #selector(goToFile(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let hint = NSTextField(labelWithString: "The oldest copy in each group is kept; tick or untick files to choose. Double-click shows a file in the panel. Moving to the Trash can be undone with ⌘Z.")
        hint.font = Theme.smallFont
        hint.textColor = .secondaryLabelColor

        for v in [top, options, scroll, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            options.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            options.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            options.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    @objc func start(_ sender: Any?) {
        if let r = running {
            r.cancel()
            return
        }
        let root = URL(fileURLWithPath: (folderField.stringValue as NSString).expandingTildeInPath)
        guard root.isExistingDirectory else {
            Dialogs.error("Find Duplicates", "\(root.path) is not a folder.")
            return
        }
        let flag = CancelFlag()
        running = flag
        startButton.title = "Stop"
        groups = []
        rebuild()
        let subfolders = subfoldersCheck.state == .on, hidden = hiddenCheck.state == .on
        let minSize = Self.minSizes[max(minSizePopup.indexOfSelectedItem, 0)].1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = DuplicateFinder.find(in: root, subfolders: subfolders, hidden: hidden, minSize: minSize, cancel: flag) { text in
                DispatchQueue.main.async { self?.statusLabel.stringValue = text }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = nil
                self.startButton.title = "Find Duplicates"
                self.groups = found
                // Keep the oldest copy, check the others.
                self.checked = Set(found.flatMap { $0.files.dropFirst().map(\.url.path) })
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        rows = []
        for (g, group) in groups.enumerated() {
            rows.append(.group(g))
            for f in group.files.indices { rows.append(.file(g, f)) }
        }
        table.reloadData()
        let wasted = groups.reduce(Int64(0)) { $0 + $1.size * Int64($1.files.count - 1) }
        let checkedSize = groups.flatMap { g in g.files.filter { checked.contains($0.url.path) } }.reduce(Int64(0)) { $0 + $1.size }
        if running == nil {
            statusLabel.stringValue = groups.isEmpty ? "No duplicates found." :
                "\(groups.count) group(s) · \(Fmt.bytes(wasted)) in extra copies · \(checked.count) checked (\(Fmt.bytes(checkedSize)))"
        }
        trashButton.isEnabled = !checked.isEmpty
    }

    @objc private func toggleCheck(_ sender: NSButton) {
        guard sender.tag < rows.count, case let .file(g, f) = rows[sender.tag] else { return }
        let path = groups[g].files[f].url.path
        if sender.state == .on { checked.insert(path) } else { checked.remove(path) }
        rebuild()
    }

    @objc private func trashChecked(_ sender: Any?) {
        // Never trash every copy of a group.
        if let g = groups.first(where: { $0.files.allSatisfy { checked.contains($0.url.path) } }) {
            Dialogs.error("Find Duplicates", "All copies of \"\(g.files[0].name)\" are checked. Keep at least one.")
            return
        }
        let urls = groups.flatMap(\.files).filter { checked.contains($0.url.path) }.map(\.url)
        guard Dialogs.confirm("Move to Trash", "Move \(urls.count) duplicate file(s) to the Trash?", ok: "Move to Trash") else { return }
        let job = DeleteJob(urls: urls, permanent: false)
        job.start(on: window) { [weak self] in
            guard let self else { return }
            if !job.trashed.isEmpty {
                self.controller?.registerUndoMove(job.trashed.map { ($0.inTrash, $0.original) }, name: "Move Duplicates to Trash")
            }
            let gone = Set(job.trashed.map(\.original.path))
            self.groups = self.groups.map { g in
                var g = g
                g.files.removeAll { gone.contains($0.url.path) }
                return g
            }.filter { $0.files.count > 1 }
            self.checked.subtract(gone)
            self.rebuild()
            self.controller?.refresh(nil)
        }
    }

    @objc private func goToFile(_ sender: Any?) {
        let r = table.clickedRow
        guard r >= 0, r < rows.count, case let .file(g, f) = rows[r] else { return }
        controller?.goToFile(groups[g].files[f].url)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let g):
            let group = groups[g]
            let tf = NSTextField(labelWithString: "\(group.files.count) identical files · \(Fmt.bytes(group.size)) each")
            tf.font = Theme.boldFont
            return tf
        case let .file(g, f):
            let item = groups[g].files[f]
            switch tableColumn?.identifier.rawValue {
            case "check":
                let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCheck(_:)))
                b.state = checked.contains(item.url.path) ? .on : .off
                b.tag = row
                return b
            case "name":
                let tf = NSTextField(labelWithString: item.name + (f == 0 ? "   (oldest)" : ""))
                tf.lineBreakMode = .byTruncatingMiddle
                return tf
            case "folder":
                let tf = NSTextField(labelWithString: item.url.deletingLastPathComponent().abbreviatedPath)
                tf.lineBreakMode = .byTruncatingHead
                tf.textColor = .secondaryLabelColor
                return tf
            default:
                return NSTextField(labelWithString: Fmt.date(item.modified))
            }
        }
    }

    func windowWillClose(_ notification: Notification) { running?.cancel() }
}
