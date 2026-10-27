import AppKit

/// Browses an archive like a folder (Enter on a .zip/.tar/... file), with extraction of selected entries.
final class ArchiveWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var openWindows: [ArchiveWindowController] = []

    private struct Entry {
        let path: String // without trailing slash
        let isDir: Bool
        let size: Int64
        let date: String
    }

    private let archive: URL
    private weak var controller: MainWindowController?
    private var entries: [String: Entry] = [:]
    private var children: [String: [String]] = [:] // dir path ("" = root) -> child paths
    private var current = ""
    private var rows: [Entry] = []
    private let table = NSTableView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Reading archive…")
    private var keyMonitor: Any?

    static func show(archive: URL, controller: MainWindowController) {
        let w = ArchiveWindowController(archive: archive, controller: controller)
        openWindows.append(w)
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
        w.load()
    }

    private init(archive: URL, controller: MainWindowController) {
        self.archive = archive
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Archive - [\(archive.path)]"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.center()
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        pathLabel.isBezeled = false
        pathLabel.drawsBackground = true
        pathLabel.backgroundColor = Theme.activeHeader
        pathLabel.textColor = .white
        pathLabel.font = Theme.boldFont
        pathLabel.lineBreakMode = .byTruncatingHead

        let cols: [(String, String, CGFloat)] = [("name", "Name", 380), ("size", "Size", 100), ("date", "Date", 160)]
        for (id, title, width) in cols {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Theme.rowHeight
        table.style = .plain
        table.allowsMultipleSelection = true
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let extractSel = NSButton(title: "F5 Extract selected…", target: self, action: #selector(extractSelected(_:)))
        let extractAll = NSButton(title: "Extract all…", target: self, action: #selector(extractAll(_:)))
        let view = NSButton(title: "F3 View", target: self, action: #selector(viewEntry(_:)))
        let openDefault = NSButton(title: "Open with default app", target: self, action: #selector(openDefault(_:)))
        statusLabel.font = Theme.smallFont
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [view, extractSel, extractAll, openDefault, statusLabel])
        buttons.spacing = 8

        for v in [pathLabel, scroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            pathLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            pathLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            pathLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            pathLabel.heightAnchor.constraint(equalToConstant: 18),
            scroll.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            switch e.keyCode {
            case 53: self.close(); return nil
            case 36, 76: self.openRow(self.table.selectedRow); return nil
            case 51: self.goUp(); return nil
            case 96: self.extractSelected(nil); return nil
            case 99: self.viewEntry(nil); return nil
            default: return e
            }
        }
    }

    private func load() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-tvf", archive.path]
        p.environment = MainWindowController.utf8Environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            statusLabel.stringValue = "Cannot read archive: \(error.localizedDescription)"
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            let status = p.terminationStatus
            DispatchQueue.main.async { self?.parse(text, status: status) }
        }
    }

    /// Parses `tar -tv` (bsdtar) output: "perms links owner group size Mon DD HH:MM|YYYY name".
    private func parse(_ text: String, status: Int32) {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count == 9 else { continue }
            var name = String(parts[8])
            if let arrow = name.range(of: " -> "), parts[0].hasPrefix("l") { name = String(name[..<arrow.lowerBound]) }
            let isDir = parts[0].hasPrefix("d") || name.hasSuffix("/")
            while name.hasSuffix("/") { name.removeLast() }
            if name.hasPrefix("./") { name.removeFirst(2) }
            guard !name.isEmpty, name != "." else { continue }
            let date = "\(parts[5]) \(parts[6]) \(parts[7])"
            add(Entry(path: name, isDir: isDir, size: Int64(parts[4]) ?? 0, date: date))
        }
        if entries.isEmpty {
            statusLabel.stringValue = status == 0 ? "Archive is empty." : "Unsupported or damaged archive."
        } else {
            let files = entries.values.filter { !$0.isDir }
            statusLabel.stringValue = "\(Fmt.int(Int64(files.count))) file(s), \(Fmt.bytes(files.reduce(0) { $0 + $1.size })) unpacked"
        }
        show("")
    }

    private func add(_ e: Entry) {
        // Create implicit parent folders (zip files often omit them).
        let comps = e.path.split(separator: "/").map(String.init)
        var parent = ""
        for (i, c) in comps.enumerated() {
            let path = parent.isEmpty ? c : parent + "/" + c
            let last = i == comps.count - 1
            if entries[path] == nil {
                entries[path] = last ? e : Entry(path: path, isDir: true, size: 0, date: "")
                children[parent, default: []].append(path)
            } else if last && e.isDir {
                entries[path] = e
            }
            parent = path
        }
    }

    private func show(_ dir: String, select: String? = nil) {
        current = dir
        let kids = (children[dir] ?? []).compactMap { entries[$0] }
        let sorted = kids.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        rows = (dir.isEmpty ? [] : [Entry(path: "..", isDir: true, size: 0, date: "")]) + sorted
        pathLabel.stringValue = " " + archive.lastPathComponent + "/" + dir
        table.reloadData()
        var row = 0
        if let select, let idx = rows.firstIndex(where: { $0.path == select }) { row = idx }
        if !rows.isEmpty {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        window?.makeFirstResponder(table)
    }

    private func goUp() {
        guard !current.isEmpty else { return }
        let parent = (current as NSString).deletingLastPathComponent
        show(parent, select: current)
    }

    private func openRow(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        let e = rows[row]
        if e.path == ".." { goUp() } else if e.isDir { show(e.path) } else { viewEntry(nil) }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        openRow(table.clickedRow)
    }

    private var selectedMembers: [String] {
        table.selectedRowIndexes.compactMap { $0 < rows.count && rows[$0].path != ".." ? rows[$0].path : nil }
    }

    /// Extracts a single file into a temporary directory and returns its location.
    private func extractToTemp(_ member: String, completion: @escaping (URL) -> Void) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("FileAdmiral-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        TaskRunner.run(title: "Extracting", executable: "/usr/bin/tar",
                       arguments: ["-xf", archive.path, "-C", tmp.path, "--", MainWindowController.tarLiteral(member)],
                       cwd: tmp, window: window, environment: MainWindowController.utf8Environment) { status, out in
            let u = tmp.appendingPathComponent(member)
            if status == 0 && pathExists(u) { completion(u) } else { Dialogs.error("Extraction failed", out) }
        }
    }

    @objc private func viewEntry(_ sender: Any?) {
        guard let m = selectedMembers.first, entries[m]?.isDir == false else { return }
        extractToTemp(m) { ViewerWindowController.show(url: $0) }
    }

    @objc private func openDefault(_ sender: Any?) {
        guard let m = selectedMembers.first, entries[m]?.isDir == false else {
            NSWorkspace.shared.open(archive)
            return
        }
        extractToTemp(m) { NSWorkspace.shared.open($0) }
    }

    private func askDestination(_ what: String) -> URL? {
        guard let c = controller else { return nil }
        guard let text = Dialogs.prompt(title: "Unpack", message: "Unpack \(what) to:", defaultValue: c.other.currentURL.path + "/",
                                        okTitle: "Unpack") else { return nil }
        let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @objc private func extractSelected(_ sender: Any?) {
        let members = selectedMembers
        guard !members.isEmpty, let dest = askDestination("\(members.count) item(s)") else { return }
        controller?.extract([archive], to: dest, members: members)
    }

    @objc private func extractAll(_ sender: Any?) {
        guard let dest = askDestination("the whole archive") else { return }
        controller?.extract([archive], to: dest, members: [])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let id = col.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.font = Theme.font
            tf.lineBreakMode = .byTruncatingMiddle
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            if id.rawValue == "size" { tf.alignment = .right }
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let e = rows[row]
        let name = e.path == ".." ? ".." : (e.path as NSString).lastPathComponent
        switch id.rawValue {
        case "name": cell.textField?.stringValue = e.isDir ? "[\(name)]" : name
        case "size": cell.textField?.stringValue = e.isDir ? "<DIR>" : Fmt.int(e.size)
        default: cell.textField?.stringValue = e.date
        }
        return cell
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        DispatchQueue.main.async { Self.openWindows.removeAll { $0 === self } }
    }
}
