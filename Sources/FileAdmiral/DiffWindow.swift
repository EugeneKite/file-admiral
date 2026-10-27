import AppKit

/// Line diff (Myers, via Swift's CollectionDifference) laid out as aligned side-by-side rows.
enum TextDiff {
    enum Kind { case equal, changed, removed, added }

    struct Row {
        let kind: Kind
        let left: Int?  // line index in the left file
        let right: Int? // line index in the right file
    }

    static func rows(_ left: [String], _ right: [String], ignoreWhitespace: Bool = false) -> [Row] {
        let norm: (String) -> String = ignoreWhitespace
            ? { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            : { $0 }
        let l = left.map(norm), r = right.map(norm)
        let diff = r.difference(from: l)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [Row] = []
        var i = 0, j = 0
        while i < l.count || j < r.count {
            let rem = i < l.count && removed.contains(i)
            let ins = j < r.count && inserted.contains(j)
            if rem && ins {
                rows.append(Row(kind: .changed, left: i, right: j))
                i += 1
                j += 1
            } else if rem {
                rows.append(Row(kind: .removed, left: i, right: nil))
                i += 1
            } else if ins {
                rows.append(Row(kind: .added, left: nil, right: j))
                j += 1
            } else {
                rows.append(Row(kind: .equal, left: i < l.count ? i : nil, right: j < r.count ? j : nil))
                i += 1
                j += 1
            }
        }
        return rows
    }

    /// Splits a file into lines, decoding UTF-8 (or the configured fallback encoding when it isn't valid UTF-8).
    static func lines(of url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let slice = data.prefix(32 << 20)
        let text: String
        if let s = String(data: slice, encoding: .utf8) {
            text = s
        } else {
            text = ViewerWindowController.decode(slice, encoding: ViewerWindowController.encodings[Settings.fallbackEncoding].1)
        }
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func isBinary(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return ((try? h.read(upToCount: 8192)) ?? Data()).contains(0)
    }

    /// Offset of the first differing byte, or nil when the files are identical. Throws when a file can't be read.
    static func firstDifference(_ a: URL, _ b: URL, cancel: CancelFlag? = nil) throws -> Int64? {
        let ha = try FileHandle(forReadingFrom: a)
        defer { try? ha.close() }
        let hb = try FileHandle(forReadingFrom: b)
        defer { try? hb.close() }
        var offset: Int64 = 0
        while cancel?.isCancelled != true {
            let da = try fill(ha, 1 << 20), db = try fill(hb, 1 << 20)
            if da == db {
                if da.isEmpty { return nil }
                offset += Int64(da.count)
                continue
            }
            let n = min(da.count, db.count)
            var i = 0
            while i < n && da[da.startIndex + i] == db[db.startIndex + i] { i += 1 }
            return offset + Int64(i)
        }
        throw DiffError(message: "Cancelled.")
    }

    /// Reads up to `count` bytes, retrying short reads (network volumes), so both sides compare equal lengths.
    private static func fill(_ h: FileHandle, _ count: Int) throws -> Data {
        var buf = Data()
        while buf.count < count {
            guard let d = try h.read(upToCount: count - buf.count), !d.isEmpty else { break }
            buf.append(d)
        }
        return buf
    }
}

struct DiffError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Files → Compare by Content: side-by-side text diff.
final class DiffWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: [DiffWindowController] = []

    private let leftURL: URL, rightURL: URL
    private var leftLines: [String] = [], rightLines: [String] = []
    private var rows: [TextDiff.Row] = []
    private var differenceStarts: [Int] = []
    private let table = NSTableView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let whitespaceCheck = NSButton(checkboxWithTitle: "Ignore whitespace", target: nil, action: nil)

    private enum Prepared {
        case binary(firstDifference: Int64?)
        case text([String], [String])
    }

    /// Compares two files; binary files get a short answer instead of a window.
    /// Reading and splitting happen off the main thread (files can be tens of megabytes).
    static func compare(_ a: URL, _ b: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let prepared = Result { () throws -> Prepared in
                if TextDiff.isBinary(a) || TextDiff.isBinary(b) {
                    return .binary(firstDifference: try TextDiff.firstDifference(a, b))
                }
                guard let l = TextDiff.lines(of: a), let r = TextDiff.lines(of: b) else {
                    throw DiffError(message: "Cannot read the files.")
                }
                return .text(l, r)
            }
            DispatchQueue.main.async {
                switch prepared {
                case .success(.binary(let offset?)):
                    Dialogs.info("Compare by Content", "The files differ.\nFirst difference at byte \(Fmt.int(offset)).")
                case .success(.binary(nil)):
                    Dialogs.info("Compare by Content", "The files are identical.")
                case .success(.text(let l, let r)):
                    let c = DiffWindowController(left: a, right: b, leftLines: l, rightLines: r)
                    open.append(c)
                    c.showWindow(nil)
                    c.window?.makeKeyAndOrderFront(nil)
                case .failure(let error):
                    Dialogs.error("Compare by Content", error.localizedDescription)
                }
            }
        }
    }

    private init(left: URL, right: URL, leftLines: [String], rightLines: [String]) {
        leftURL = left
        rightURL = right
        self.leftLines = leftLines
        self.rightLines = rightLines
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Compare: \(left.lastPathComponent) ↔ \(right.lastPathComponent)"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.setFrameAutosaveName("CompareFiles")
        buildUI()
        recompute()
        w.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let prev = NSButton(title: "▲ Previous", target: self, action: #selector(previousDifference(_:)))
        prev.keyEquivalent = "["
        let next = NSButton(title: "▼ Next difference", target: self, action: #selector(nextDifference(_:)))
        next.keyEquivalent = "]"
        whitespaceCheck.target = self
        whitespaceCheck.action = #selector(optionChanged(_:))
        infoLabel.font = Theme.smallFont
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [prev, next, whitespaceCheck, infoLabel])
        bar.spacing = 10

        let mono = NSFont.monospacedSystemFont(ofSize: Theme.fontSize, weight: .regular)
        let cols: [(String, String, CGFloat)] = [("ln", "", 46), ("left", leftURL.path, 520), ("rn", "", 46), ("right", rightURL.path, 520)]
        for (id, title, width) in cols {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            if id == "ln" || id == "rn" { c.maxWidth = 70 }
            c.headerCell.lineBreakMode = .byTruncatingHead
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = ceil(mono.ascender - mono.descender + mono.leading) + 4
        table.intercellSpacing = NSSize(width: 4, height: 0)
        table.style = .plain
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder

        for v in [bar, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// Bumped for every recompute, so a slow diff that finishes after the next one is dropped.
    private var computeGeneration = 0

    private func recompute() {
        computeGeneration += 1
        let generation = computeGeneration
        let l = leftLines, r = rightLines, ignoreWhitespace = whitespaceCheck.state == .on
        infoLabel.stringValue = "Comparing…"
        // Myers diff is O(N·D): two large, mostly different files take seconds, so never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rows = TextDiff.rows(l, r, ignoreWhitespace: ignoreWhitespace)
            // A "difference" is a run of consecutive non-equal rows.
            let starts = rows.indices.filter { i in rows[i].kind != .equal && (i == 0 || rows[i - 1].kind == .equal) }
            DispatchQueue.main.async {
                guard let self, self.computeGeneration == generation else { return }
                self.rows = rows
                self.differenceStarts = starts
                self.table.reloadData()
                self.infoLabel.stringValue = starts.isEmpty
                    ? "The files are identical\(ignoreWhitespace ? " (ignoring whitespace)" : "")."
                    : "\(starts.count) difference(s) · \(l.count) / \(r.count) lines"
                if let first = starts.first { self.jump(to: first) }
            }
        }
    }

    @objc private func optionChanged(_ sender: Any?) { recompute() }

    private func jump(to row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        let visible = table.rows(in: table.visibleRect)
        table.scrollRowToVisible(min(row + max(visible.length / 2 - 1, 0), rows.count - 1))
        table.scrollRowToVisible(row)
    }

    @objc private func nextDifference(_ sender: Any?) {
        let current = table.selectedRow
        if let next = differenceStarts.first(where: { $0 > current }) { jump(to: next) } else { NSSound.beep() }
    }

    @objc private func previousDifference(_ sender: Any?) {
        let current = table.selectedRow
        if let prev = differenceStarts.last(where: { $0 < current }) { jump(to: prev) } else { NSSound.beep() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let r = rows[row]
        let tf = (tableView.makeView(withIdentifier: .init(id), owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = .init(id)
            t.font = .monospacedSystemFont(ofSize: Theme.fontSize, weight: .regular)
            t.lineBreakMode = .byClipping
            return t
        }()
        switch id {
        case "ln":
            tf.stringValue = r.left.map { "\($0 + 1)" } ?? ""
            tf.textColor = .tertiaryLabelColor
            tf.alignment = .right
        case "rn":
            tf.stringValue = r.right.map { "\($0 + 1)" } ?? ""
            tf.textColor = .tertiaryLabelColor
            tf.alignment = .right
        case "left":
            tf.stringValue = r.left.map { leftLines[$0].replacingOccurrences(of: "\t", with: "    ") } ?? ""
            tf.textColor = .labelColor
        default:
            tf.stringValue = r.right.map { rightLines[$0].replacingOccurrences(of: "\t", with: "    ") } ?? ""
            tf.textColor = .labelColor
        }
        return tf
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = DiffRowView()
        v.kind = rows[row].kind
        return v
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { Self.open.removeAll { $0 === self } }
    }
}

/// Colors a diff row: changed yellow, removed (left only) red, added (right only) green.
private final class DiffRowView: NSTableRowView {
    var kind: TextDiff.Kind = .equal

    override func drawBackground(in dirtyRect: NSRect) {
        let color: NSColor?
        switch kind {
        case .equal: color = nil
        case .changed: color = NSColor.systemYellow.withAlphaComponent(0.22)
        case .removed: color = NSColor.systemRed.withAlphaComponent(0.18)
        case .added: color = NSColor.systemGreen.withAlphaComponent(0.2)
        }
        (color ?? .textBackgroundColor).setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
        bounds.fill()
    }
}
