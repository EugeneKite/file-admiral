import AppKit

/// "Find Files" dialog (Alt+F7).
final class SearchWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var shared: SearchWindowController?

    private weak var controller: MainWindowController?
    private let maskField = NSTextField(string: "*")
    private let dirField = NSTextField(string: "")
    private let textField = NSTextField(string: "")
    private let caseCheck = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    private let subdirCheck = NSButton(checkboxWithTitle: "Search subdirectories", target: nil, action: nil)
    private let hiddenCheck = NSButton(checkboxWithTitle: "Include hidden files", target: nil, action: nil)
    private let packageCheck = NSButton(checkboxWithTitle: "Search inside packages (.app)", target: nil, action: nil)
    private let spotlightCheck = NSButton(checkboxWithTitle: "Use Spotlight index (instant; indexed locations only)",
                                          target: nil, action: nil)
    private let startButton = NSButton(title: "Start search", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private var results: [URL] = []
    private var flag: CancelFlag?

    static func show(controller: MainWindowController, startDir: URL) {
        let s = shared ?? SearchWindowController(controller: controller)
        shared = s
        if s.flag == nil { s.dirField.stringValue = startDir.path }
        s.showWindow(nil)
        s.window?.makeKeyAndOrderFront(nil)
        s.window?.makeFirstResponder(s.maskField)
    }

    private init(controller: MainWindowController) {
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Find Files"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 380)
        super.init(window: w)
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("FindFiles")
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        maskField.placeholderString = "*.txt;*.md   (* = all files)"
        textField.placeholderString = "optional text to find inside files"
        subdirCheck.state = .on

        let browse = NSButton(title: "…", target: self, action: #selector(browse(_:)))
        browse.bezelStyle = .rounded
        let dirRow = NSStackView(views: [dirField, browse])
        dirRow.spacing = 4
        dirField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let checks = NSStackView(views: [subdirCheck, caseCheck, hiddenCheck, packageCheck, spotlightCheck])
        checks.orientation = .vertical
        checks.alignment = .leading
        checks.spacing = 4

        let grid = NSGridView(views: [
            [label("Search for:"), maskField],
            [label("Search in:"), dirRow],
            [label("Find text:"), textField],
            [NSGridCell.emptyContentView, checks],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 8

        startButton.target = self
        startButton.action = #selector(startStop(_:))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        let goButton = NSButton(title: "Go to file", target: self, action: #selector(goToFile(_:)))
        let viewButton = NSButton(title: "View (F3)", target: self, action: #selector(viewFile(_:)))
        let feedButton = NSButton(title: "Mark in panel", target: self, action: #selector(markInPanel(_:)))
        feedButton.toolTip = "Navigate to the search folder and mark found files that are directly inside it"
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = Theme.smallFont
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [startButton, goButton, viewButton, feedButton, statusLabel])
        buttons.spacing = 8

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"
        nameCol.width = 220
        let dirCol = NSTableColumn(identifier: .init("dir"))
        dirCol.title = "Folder"
        dirCol.width = 420
        table.addTableColumn(nameCol)
        table.addTableColumn(dirCol)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Theme.rowHeight
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(goToFile(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for v in [grid, buttons, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            maskField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    @objc private func browse(_ sender: Any?) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: dirField.stringValue)
        if p.runModal() == .OK, let u = p.url { dirField.stringValue = u.path }
    }

    /// The mdfind process of a running Spotlight search, so Stop can end it.
    private var spotlightRunner: ProcessRunner?

    @objc private func startStop(_ sender: Any?) {
        if let f = flag {
            f.cancel()
            spotlightRunner?.terminate()
            return
        }
        results.removeAll()
        table.reloadData()
        let root = URL(fileURLWithPath: (dirField.stringValue as NSString).expandingTildeInPath)
        guard root.isExistingDirectory else {
            Dialogs.error("Invalid folder", "\(root.path) is not a folder.")
            return
        }
        let mask = FileMask(maskField.stringValue.isEmpty ? "*" : maskField.stringValue)
        let needle = textField.stringValue
        let caseSensitive = caseCheck.state == .on
        let subdirs = subdirCheck.state == .on
        let hidden = hiddenCheck.state == .on
        let packages = packageCheck.state == .on
        let f = CancelFlag()
        flag = f
        startButton.title = "Stop"
        statusLabel.stringValue = "Searching…"
        let needleData = Data(needle.utf8)

        if spotlightCheck.state == .on {
            let maskText = maskField.stringValue
            let runner = ProcessRunner()
            spotlightRunner = runner
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let found = SearchWindowController.spotlight(root: root, maskText: maskText, needle: needle,
                                                             caseSensitive: caseSensitive, subdirs: subdirs, hidden: hidden,
                                                             packages: packages, cancel: f, runner: runner)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.spotlightRunner = nil
                    self.append(found, status: "")
                    self.flag = nil
                    self.startButton.title = "Start search"
                    self.statusLabel.stringValue = "Spotlight: \(Fmt.int(Int64(found.count))) found."
                }
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var options: FileManager.DirectoryEnumerationOptions = []
            if !hidden { options.insert(.skipsHiddenFiles) }
            if !subdirs { options.insert(.skipsSubdirectoryDescendants) }
            if !packages { options.insert(.skipsPackageDescendants) }
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey, .volumeIdentifierKey]
            let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options,
                                                    errorHandler: { _, _ in true })
            // Stay on the volume the search started on (like `find -x`): searching "/" must not walk every
            // mounted disk and network share, nor the duplicate firmlinked view under /System/Volumes/Data.
            let rootVolume = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
            var batch: [URL] = []
            var last = Date()
            var scanned = 0
            while let u = en?.nextObject() as? URL {
                if f.isCancelled { break }
                scanned += 1
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true {
                    if u.path == "/System/Volumes/Data"
                        || (rootVolume != nil && (v?.volumeIdentifier as? NSObject) != rootVolume) {
                        en?.skipDescendants()
                        continue
                    }
                }
                // As in TC, "Case sensitive" applies to the text search; file name masks are case-insensitive.
                if mask.matches(u.lastPathComponent) {
                    if needle.isEmpty {
                        batch.append(u)
                    } else if v?.isRegularFile == true,
                              SearchWindowController.file(u, contains: needle, data: needleData, caseSensitive: caseSensitive,
                                                          cancel: f) {
                        batch.append(u)
                    }
                }
                if Date().timeIntervalSince(last) > 0.2 {
                    let b = batch, n = scanned, dir = u.deletingLastPathComponent().path
                    batch.removeAll()
                    last = Date()
                    DispatchQueue.main.async { self?.append(b, status: "Scanned \(Fmt.int(Int64(n))): \(dir)") }
                }
            }
            let b = batch, n = scanned, cancelled = f.isCancelled
            DispatchQueue.main.async {
                guard let self else { return }
                self.append(b, status: "")
                self.flag = nil
                self.startButton.title = "Start search"
                self.statusLabel.stringValue = "\(cancelled ? "Stopped" : "Done"). \(Fmt.int(Int64(self.results.count))) found, \(Fmt.int(Int64(n))) scanned."
            }
        }
    }

    /// Finds files through the Spotlight index (mdfind), then applies the same filters as the normal search.
    static func spotlight(root: URL, maskText: String, needle: String, caseSensitive: Bool, subdirs: Bool, hidden: Bool,
                          packages: Bool, cancel: CancelFlag, runner: ProcessRunner = ProcessRunner()) -> [URL] {
        let mask = FileMask(maskText.isEmpty ? "*" : maskText)
        func quoted(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var clauses: [String] = []
        if !mask.include.isEmpty && !mask.include.contains("*") {
            clauses.append("(" + mask.include.map { "kMDItemFSName == \"\(quoted($0))\"cd" }.joined(separator: " || ") + ")")
        }
        if !needle.isEmpty {
            clauses.append("kMDItemTextContent == \"*\(quoted(needle))*\"cd")
        }
        if clauses.isEmpty { clauses.append("kMDItemFSName == \"*\"") }
        let query = clauses.joined(separator: " && ")
        guard let r = try? runner.run("/usr/bin/mdfind", ["-onlyin", root.path, query]), !cancel.isCancelled else { return [] }
        let rootPath = root.standardizedFileURL.path
        var result: [URL] = []
        for line in String(decoding: r.stdout, as: UTF8.self).split(separator: "\n") {
            if cancel.isCancelled { break }
            let url = URL(fileURLWithPath: String(line))
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") || rootPath == "/" else { continue }
            let rel = path.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1).split(separator: "/")
            if !subdirs && rel.count > 1 { continue }
            if !hidden && rel.contains(where: { $0.hasPrefix(".") }) { continue }
            if !packages && rel.dropLast().contains(where: { FileItem.packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
                continue
            }
            guard mask.matches(url.lastPathComponent) else { continue }
            // Spotlight's text match is case-insensitive; check the exact case when asked.
            if !needle.isEmpty && caseSensitive
                && !file(url, contains: needle, data: Data(needle.utf8), caseSensitive: true, cancel: cancel) { continue }
            result.append(url)
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Searches a file in 1 MB chunks (overlapping by the needle length), so memory stays flat and
    /// cancellation is checked while large files are read.
    static func file(_ url: URL, contains needle: String, data needleData: Data, caseSensitive: Bool,
                     cancel: CancelFlag) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let chunkSize = 1 << 20
        // Enough bytes to hold the needle in any UTF-8 case form across a chunk boundary.
        let overlap = max(needleData.count * 4, 16)
        var carry = Data()
        while !cancel.isCancelled {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            let window = carry + chunk
            if window.range(of: needleData) != nil { return true }
            if !caseSensitive {
                let text = String(decoding: window, as: UTF8.self)
                if text.range(of: needle, options: .caseInsensitive) != nil { return true }
            }
            carry = window.suffix(overlap)
        }
        return false
    }

    private func append(_ urls: [URL], status: String) {
        if !urls.isEmpty {
            results.append(contentsOf: urls)
            table.reloadData()
        }
        if !status.isEmpty { statusLabel.stringValue = "\(Fmt.int(Int64(results.count))) found. " + status }
    }

    private var selectedURL: URL? {
        // clickedRow is only current during a click's own action; the buttons act on the keyboard selection.
        let r = table.selectedRow
        return r >= 0 && r < results.count ? results[r] : nil
    }

    @objc private func goToFile(_ sender: Any?) {
        guard let u = selectedURL else { return }
        controller?.goToFile(u)
    }

    @objc private func viewFile(_ sender: Any?) {
        guard let u = selectedURL, !u.isExistingDirectory else { return }
        ViewerWindowController.show(url: u)
    }

    @objc private func markInPanel(_ sender: Any?) {
        let root = URL(fileURLWithPath: (dirField.stringValue as NSString).expandingTildeInPath).standardizedFileURL
        let names = Set(results.filter { $0.deletingLastPathComponent().standardizedFileURL == root }.map(\.lastPathComponent))
        controller?.showAndMark(dir: root, names: names)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let id = col.identifier
        let tf = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.lineBreakMode = id.rawValue == "dir" ? .byTruncatingHead : .byTruncatingTail
            t.font = Theme.font
            return t
        }()
        let u = results[row]
        tf.stringValue = id.rawValue == "name" ? u.lastPathComponent : u.deletingLastPathComponent().path
        return tf
    }

    func windowWillClose(_ notification: Notification) {
        flag?.cancel()
    }
}
