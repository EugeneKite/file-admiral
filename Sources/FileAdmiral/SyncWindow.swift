import AppKit

/// One row of a folder comparison.
struct SyncItem {
    enum State { case equal, leftOnly, rightOnly, leftNewer, rightNewer, differ }
    enum Action: CaseIterable { case none, leftToRight, rightToLeft, deleteLeft, deleteRight }

    let path: String // relative path
    let isDirectory: Bool
    let left: FileItem?
    let right: FileItem?
    let state: State
    var action: Action

    var symbol: String {
        switch action {
        case .none: return state == .equal ? "=" : "≠"
        case .leftToRight: return "→"
        case .rightToLeft: return "←"
        case .deleteLeft: return "✕ left"
        case .deleteRight: return "✕ right"
        }
    }
}

enum SyncDirection: Int { case both, leftToRight, rightToLeft }

/// Folder comparison used by the Synchronize window (and the self-test).
enum FolderSync {
    struct Options {
        var subfolders = true
        var byContent = false
        var direction = SyncDirection.both
        var deleteExtras = false
        var showHidden = false
    }

    struct UnreadableFolder: LocalizedError {
        let path: String
        let reason: String
        var errorDescription: String? { "Cannot read \(path)\n\(reason)" }
    }

    /// Compares two folder trees. Folders that exist on one side only appear as a single row.
    /// Throws when a folder on either side cannot be listed: an unreadable folder must never look empty,
    /// because "empty" in mirror mode means "delete everything on the other side".
    static func compare(_ left: URL, _ right: URL, options: Options, cancel: CancelFlag) throws -> [SyncItem] {
        var result: [SyncItem] = []
        func list(_ dir: URL) throws -> [String: FileItem] {
            let items: [FileItem]
            do {
                items = try FileItem.list(dir, showHidden: options.showHidden)
            } catch {
                throw UnreadableFolder(path: dir.path, reason: error.localizedDescription)
            }
            var map: [String: FileItem] = [:]
            for it in items where !it.isSymlink || !it.isDirectory {
                map[it.name] = it
            }
            return map
        }
        func walk(_ rel: String) throws {
            if cancel.isCancelled { return }
            let l = try list(rel.isEmpty ? left : left.appendingPathComponent(rel))
            let r = try list(rel.isEmpty ? right : right.appendingPathComponent(rel))
            for name in Set(l.keys).union(r.keys).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let path = rel.isEmpty ? name : rel + "/" + name
                let a = l[name], b = r[name]
                if let a, let b, a.isDirectory && b.isDirectory {
                    if options.subfolders { try walk(path) }
                    continue
                }
                if let a, let b, a.isDirectory != b.isDirectory {
                    result.append(SyncItem(path: path, isDirectory: a.isDirectory, left: a, right: b, state: .differ, action: .none))
                    continue
                }
                let state: SyncItem.State
                switch (a, b) {
                case (nil, .some): state = .rightOnly
                case (.some, nil): state = .leftOnly
                case let (.some(x), .some(y)):
                    if options.byContent {
                        state = x.size == y.size && sameContent(x.url, y.url, cancel: cancel) ? .equal
                            : (abs(x.modified.timeIntervalSince(y.modified)) <= 2 ? .differ
                               : (x.modified > y.modified ? .leftNewer : .rightNewer))
                    } else if x.size == y.size && abs(x.modified.timeIntervalSince(y.modified)) <= 2 {
                        // Two seconds of tolerance for FAT/exFAT time stamps.
                        state = .equal
                    } else if abs(x.modified.timeIntervalSince(y.modified)) <= 2 {
                        state = .differ
                    } else {
                        state = x.modified > y.modified ? .leftNewer : .rightNewer
                    }
                default: continue
                }
                let isDir = (a ?? b)?.isDirectory ?? false
                result.append(SyncItem(path: path, isDirectory: isDir, left: a, right: b, state: state,
                                       action: defaultAction(state, options)))
            }
        }
        try walk("")
        return result
    }

    static func defaultAction(_ state: SyncItem.State, _ o: Options) -> SyncItem.Action {
        switch (o.direction, state) {
        case (_, .equal): return .none
        case (.both, .leftOnly), (.both, .leftNewer): return .leftToRight
        case (.both, .rightOnly), (.both, .rightNewer): return .rightToLeft
        case (.both, .differ): return .none // conflict: the user decides
        case (.leftToRight, .rightOnly): return o.deleteExtras ? .deleteRight : .none
        case (.leftToRight, _): return .leftToRight
        case (.rightToLeft, .leftOnly): return o.deleteExtras ? .deleteLeft : .none
        case (.rightToLeft, _): return .rightToLeft
        }
    }

    static func sameContent(_ a: URL, _ b: URL, cancel: CancelFlag) -> Bool {
        // A read error counts as "different": the worst case is one unnecessary copy.
        do { return try TextDiff.firstDifference(a, b, cancel: cancel) == nil } catch { return false }
    }
}

extension SyncItem {
    /// A folder on one side and a file with the same name on the other: never resolved automatically.
    var isTypeConflict: Bool {
        guard let left, let right else { return false }
        return left.isDirectory != right.isDirectory
    }
}

/// Executes the chosen actions: copies overwrite (they were approved), deletions go to the Trash.
final class SyncJob: FileJob {
    private let items: [SyncItem]
    private let left: URL, right: URL

    init(items: [SyncItem], left: URL, right: URL) {
        self.items = items.filter { $0.action != .none }
        self.left = left
        self.right = right
        super.init(title: "Synchronizing")
    }

    override func run() {
        for (i, item) in items.enumerated() {
            if flag.isCancelled { return }
            let l = left.appendingPathComponent(item.path), r = right.appendingPathComponent(item.path)
            DispatchQueue.main.async {
                self.sheet.update(from: item.path, to: "", file: 0, total: Double(i) / Double(max(self.items.count, 1)),
                                  info: "\(i + 1) of \(self.items.count)")
            }
            switch item.action {
            case .none: break
            case .leftToRight, .rightToLeft:
                let (src, dst) = item.action == .leftToRight ? (l, r) : (r, l)
                try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A nested copy job does the actual work (temp file + rename, metadata, error handling).
                // Its own sheet is never shown: its progress is forwarded to this job's sheet, and Cancel
                // here stops it. (Jobs own a progress window, so they must be created on the main thread.)
                let overall = Double(i) / Double(max(items.count, 1))
                let copy = DispatchQueue.main.sync { () -> TransferJob in
                    let job = TransferJob(sources: [src], destDir: dst.deletingLastPathComponent(), newName: nil, move: false,
                                          overwriteAll: true)
                    job.sheet.onUpdate = { [weak self] from, fileFraction, info in
                        self?.sheet.update(from: item.path, to: "→ " + from, file: fileFraction, total: overall, info: info)
                    }
                    self.sheet.onCancel = { [weak job] in job?.flag.cancel() }
                    return job
                }
                copy.run()
                DispatchQueue.main.sync { self.sheet.onCancel = nil }
                if copy.flag.isCancelled { flag.cancel() }
            case .deleteLeft, .deleteRight:
                let target = item.action == .deleteLeft ? l : r
                do {
                    try FileManager.default.trashItem(at: target, resultingItemURL: nil)
                } catch {
                    if !reportError("Cannot move \(target.path) to the Trash\n\(error.localizedDescription)") { return }
                }
            }
        }
    }
}

/// Commands → Synchronize Folders (TC "Synchronize dirs").
final class SyncWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var shared: SyncWindowController?
    private weak var controller: MainWindowController?

    private let leftField = NSTextField()
    private let rightField = NSTextField()
    private let directionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let subfoldersCheck = NSButton(checkboxWithTitle: "Subfolders", target: nil, action: nil)
    private let contentCheck = NSButton(checkboxWithTitle: "Compare contents", target: nil, action: nil)
    private let deleteCheck = NSButton(checkboxWithTitle: "Delete extra files on the target (to Trash)", target: nil, action: nil)
    private let equalCheck = NSButton(checkboxWithTitle: "Show equal files", target: nil, action: nil)
    private let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    private let syncButton = NSButton(title: "Synchronize…", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private var items: [SyncItem] = []
    private var shown: [Int] = [] // indexes into items
    private var comparing: CancelFlag?

    @discardableResult
    static func show(controller: MainWindowController, left: URL, right: URL) -> SyncWindowController {
        let c = shared ?? SyncWindowController(controller: controller)
        shared = c
        if c.comparing == nil {
            c.leftField.stringValue = left.path
            c.rightField.stringValue = right.path
        }
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        return c
    }

    private init(controller: MainWindowController) {
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Synchronize Folders"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 420)
        super.init(window: w)
        w.delegate = self
        w.setFrameAutosaveName("SyncFolders")
        buildUI()
        w.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        directionPopup.addItems(withTitles: ["Both ways (newer wins)", "Left → Right (mirror)", "Right → Left (mirror)"])
        subfoldersCheck.state = .on
        for c in [directionPopup, subfoldersCheck, contentCheck, deleteCheck] as [NSControl] {
            c.target = self
            c.action = #selector(optionsChanged(_:))
        }
        equalCheck.target = self
        equalCheck.action = #selector(filterChanged(_:))
        deleteCheck.isEnabled = false
        compareButton.target = self
        compareButton.action = #selector(compare(_:))
        compareButton.keyEquivalent = "\r"
        syncButton.target = self
        syncButton.action = #selector(synchronize(_:))
        syncButton.isEnabled = false
        statusLabel.font = Theme.smallFont
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let paths = NSGridView(views: [[NSTextField(labelWithString: "Left:"), leftField],
                                       [NSTextField(labelWithString: "Right:"), rightField]])
        paths.rowSpacing = 6
        paths.columnSpacing = 6
        leftField.widthAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true
        let options = NSStackView(views: [directionPopup, subfoldersCheck, contentCheck, deleteCheck])
        options.spacing = 14
        let buttons = NSStackView(views: [compareButton, syncButton, equalCheck, statusLabel])
        buttons.spacing = 10

        let cols: [(String, String, CGFloat)] = [("path", "File", 380), ("left", "Left", 190), ("action", "Action", 70),
                                                 ("right", "Right", 190)]
        for (id, title, width) in cols {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Theme.rowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.target = self
        table.action = #selector(rowClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let hint = NSTextField(labelWithString: "Click an action to change it: → copy to the right, ← copy to the left, ✕ move to Trash, = / ≠ do nothing.")
        hint.font = Theme.smallFont
        hint.textColor = .secondaryLabelColor

        for v in [paths, options, buttons, scroll, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            paths.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            paths.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            paths.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            options.topAnchor.constraint(equalTo: paths.bottomAnchor, constant: 10),
            options.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    private var options: FolderSync.Options {
        var o = FolderSync.Options()
        o.subfolders = subfoldersCheck.state == .on
        o.byContent = contentCheck.state == .on
        o.direction = SyncDirection(rawValue: directionPopup.indexOfSelectedItem) ?? .both
        o.deleteExtras = deleteCheck.state == .on && o.direction != .both
        o.showHidden = controller?.showHidden ?? false
        return o
    }

    @objc private func optionsChanged(_ sender: Any?) {
        deleteCheck.isEnabled = directionPopup.indexOfSelectedItem != 0
        // Re-apply default actions for the new direction without comparing again.
        let o = options
        for i in items.indices {
            items[i].action = items[i].isTypeConflict ? .none : FolderSync.defaultAction(items[i].state, o)
        }
        if sender as? NSButton === contentCheck || sender as? NSButton === subfoldersCheck { compare(nil) } else { refilter() }
    }

    @objc private func filterChanged(_ sender: Any?) { refilter() }

    private func refilter() {
        let showEqual = equalCheck.state == .on
        shown = items.indices.filter { showEqual || items[$0].state != .equal }
        table.reloadData()
        let copies = items.filter { $0.action == .leftToRight || $0.action == .rightToLeft }.count
        let deletes = items.filter { $0.action == .deleteLeft || $0.action == .deleteRight }.count
        let conflicts = items.filter { $0.state == .differ && $0.action == .none }.count
        let equal = items.filter { $0.state == .equal }.count
        statusLabel.stringValue = items.isEmpty ? "" :
            "\(equal) equal · \(copies) to copy · \(deletes) to delete · \(conflicts) conflict(s)"
        syncButton.isEnabled = copies + deletes > 0
    }

    @objc func compare(_ sender: Any?) {
        comparing?.cancel()
        let left = URL(fileURLWithPath: (leftField.stringValue as NSString).expandingTildeInPath)
        let right = URL(fileURLWithPath: (rightField.stringValue as NSString).expandingTildeInPath)
        guard left.isExistingDirectory, right.isExistingDirectory else {
            Dialogs.error("Synchronize", "Both paths must be existing local folders.")
            return
        }
        let flag = CancelFlag()
        comparing = flag
        statusLabel.stringValue = "Comparing…"
        compareButton.isEnabled = false
        let o = options
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FolderSync.compare(left, right, options: o, cancel: flag) }
            DispatchQueue.main.async {
                guard let self, self.comparing === flag else { return }
                self.comparing = nil
                self.compareButton.isEnabled = true
                switch result {
                case .success(let items):
                    self.items = items
                    self.refilter()
                case .failure(let error):
                    self.items = []
                    self.refilter()
                    self.statusLabel.stringValue = "Comparison aborted."
                    Dialogs.error("Synchronize", "The folders were not compared, so nothing can be synchronized.\n\n"
                                  + error.localizedDescription
                                  + "\n\nIf this is a protected folder, grant access in Configuration → Permissions.")
                }
            }
        }
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow, col = table.clickedColumn
        guard row >= 0, row < shown.count, col >= 0, table.tableColumns[col].identifier.rawValue == "action" else { return }
        let i = shown[row]
        let item = items[i]
        guard !item.isTypeConflict else {
            NSSound.beep()
            statusLabel.stringValue = "\"\(item.path)\" is a folder on one side and a file on the other; resolve it by hand."
            return
        }
        // Cycle through the actions that make sense for this row.
        var choices: [SyncItem.Action] = [.none]
        if item.left != nil { choices.append(.leftToRight) }
        if item.right != nil { choices.append(.rightToLeft) }
        if item.left != nil && item.right == nil { choices.append(.deleteLeft) }
        if item.right != nil && item.left == nil { choices.append(.deleteRight) }
        let next = choices[((choices.firstIndex(of: item.action) ?? 0) + 1) % choices.count]
        items[i].action = next
        refilter()
    }

    @objc private func synchronize(_ sender: Any?) {
        let copies = items.filter { $0.action == .leftToRight || $0.action == .rightToLeft }.count
        let deletes = items.filter { $0.action == .deleteLeft || $0.action == .deleteRight }.count
        var msg = "Copy \(copies) item(s), replacing older versions on the other side."
        if deletes > 0 { msg += "\nMove \(deletes) item(s) to the Trash." }
        guard Dialogs.confirm("Synchronize", msg, ok: "Synchronize") else { return }
        let left = URL(fileURLWithPath: (leftField.stringValue as NSString).expandingTildeInPath)
        let right = URL(fileURLWithPath: (rightField.stringValue as NSString).expandingTildeInPath)
        let job = SyncJob(items: items, left: left, right: right)
        job.start(on: window) { [weak self] in
            self?.controller?.refresh(nil)
            self?.compare(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    private func describe(_ it: FileItem?) -> String {
        guard let it else { return "" }
        return (it.isDirectory ? "<DIR>" : Fmt.size(it.size)) + "  " + Fmt.date(it.modified)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let item = items[shown[row]]
        let tf = NSTextField(labelWithString: "")
        tf.font = Theme.font
        tf.lineBreakMode = .byTruncatingMiddle
        switch col.identifier.rawValue {
        case "path":
            tf.stringValue = item.isDirectory ? "[\(item.path)]" : item.path
        case "left":
            tf.stringValue = describe(item.left)
            if item.state == .leftNewer { tf.textColor = .systemGreen }
        case "right":
            tf.stringValue = describe(item.right)
            if item.state == .rightNewer { tf.textColor = .systemGreen }
        default:
            tf.stringValue = item.symbol
            tf.alignment = .center
            tf.font = .boldSystemFont(ofSize: Theme.fontSize + 1)
            switch item.action {
            case .leftToRight, .rightToLeft: tf.textColor = .systemBlue
            case .deleteLeft, .deleteRight: tf.textColor = .systemRed
            case .none: tf.textColor = item.state == .differ ? .systemOrange : .secondaryLabelColor
            }
        }
        return tf
    }

    func windowWillClose(_ notification: Notification) { comparing?.cancel() }
}
