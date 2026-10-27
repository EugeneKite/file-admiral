import AppKit
import Darwin

/// Multi-Rename Tool (Ctrl+M in TC, ⌘M here).
final class MultiRenameWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private static var openWindows: [MultiRenameWindowController] = []

    private var urls: [URL]
    private var newNames: [String] = []
    private var undoPairs: [(from: URL, to: URL)] = []
    private let completion: () -> Void

    private let nameMask = NSTextField(string: "[N]")
    private let extMask = NSTextField(string: "[E]")
    private let searchField = NSTextField(string: "")
    private let replaceField = NSTextField(string: "")
    private let regexCheck = NSButton(checkboxWithTitle: "Regular expressions", target: nil, action: nil)
    private let caseCheck = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    private let casePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let counterStart = NSTextField(string: "1")
    private let counterStep = NSTextField(string: "1")
    private let counterDigits = NSTextField(string: "1")
    private let table = NSTableView()
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    private static let tokenRegex = try! NSRegularExpression(pattern: #"\[([A-Za-z]+)(\d+)?(-(\d*))?\]"#)

    static func show(urls: [URL], completion: @escaping () -> Void) {
        let c = MultiRenameWindowController(urls: urls, completion: completion)
        openWindows.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private init(urls: [URL], completion: @escaping () -> Void) {
        self.urls = urls
        self.completion = completion
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Multi-Rename Tool"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 700, height: 420)
        super.init(window: w)
        w.delegate = self
        w.center()
        buildUI()
        compute()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func box(_ title: String, _ content: NSView) -> NSBox {
        let b = NSBox()
        b.title = title
        b.titleFont = Theme.smallFont
        content.translatesAutoresizingMaskIntoConstraints = false
        b.contentView?.addSubview(content)
        if let cv = b.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 6),
                content.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -6),
                content.topAnchor.constraint(equalTo: cv.topAnchor, constant: 6),
                content.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -6),
            ])
        }
        return b
    }

    private func placeholderMenu(for field: NSTextField) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: true)
        p.controlSize = .small
        p.addItem(withTitle: "[…]")
        let tokens = [
            ("[N] Name", "[N]"), ("[N1-3] Name chars 1–3", "[N1-3]"), ("[E] Extension", "[E]"),
            ("[C] Counter", "[C]"), ("[P] Parent folder", "[P]"), ("[YMD] Date", "[YMD]"),
            ("[hms] Time", "[hms]"), ("[Y] Year", "[Y]"), ("[M] Month", "[M]"), ("[D] Day", "[D]"),
        ]
        for (title, token) in tokens {
            let mi = NSMenuItem(title: title, action: #selector(insertToken(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = (field, token)
            p.menu?.addItem(mi)
        }
        return p
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        for f in [nameMask, extMask, searchField, replaceField, counterStart, counterStep, counterDigits] {
            f.delegate = self
            f.font = Theme.font
        }
        for c in [regexCheck, caseCheck] {
            c.target = self
            c.action = #selector(optionChanged(_:))
            c.controlSize = .small
        }
        casePopup.addItems(withTitles: ["Unchanged", "lowercase", "UPPERCASE", "First letter uppercase", "First Of Each Word Uppercase"])
        casePopup.target = self
        casePopup.action = #selector(optionChanged(_:))

        let maskGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameMask, placeholderMenu(for: nameMask)],
            [NSTextField(labelWithString: "Extension:"), extMask, placeholderMenu(for: extMask)],
        ])
        maskGrid.rowSpacing = 6
        maskGrid.columnSpacing = 6
        nameMask.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let srGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Search for:"), searchField],
            [NSTextField(labelWithString: "Replace with:"), replaceField],
            [NSGridCell.emptyContentView, NSStackView(views: [regexCheck, caseCheck])],
        ])
        srGrid.rowSpacing = 6
        srGrid.columnSpacing = 6
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        for f in [counterStart, counterStep, counterDigits] { f.widthAnchor.constraint(equalToConstant: 50).isActive = true }
        let counterGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Start at:"), counterStart],
            [NSTextField(labelWithString: "Step by:"), counterStep],
            [NSTextField(labelWithString: "Digits:"), counterDigits],
        ])
        counterGrid.rowSpacing = 6
        counterGrid.columnSpacing = 6

        let caseStack = NSStackView(views: [NSTextField(labelWithString: "Convert name to:"), casePopup])
        caseStack.orientation = .vertical
        caseStack.alignment = .leading
        caseStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        let top = NSStackView(views: [
            box("Rename mask", maskGrid),
            box("Search and replace", srGrid),
            box("Counter [C]", counterGrid),
            box("Upper/lowercase", caseStack),
        ])
        top.alignment = .top
        top.spacing = 8
        top.distribution = .fill

        let oldCol = NSTableColumn(identifier: .init("old"))
        oldCol.title = "Old name"
        oldCol.width = 380
        let newCol = NSTableColumn(identifier: .init("new"))
        newCol.title = "New name"
        newCol.width = 380
        table.addTableColumn(oldCol)
        table.addTableColumn(newCol)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Theme.rowHeight
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let start = NSButton(title: "Start!", target: self, action: #selector(startRename(_:)))
        start.keyEquivalent = "\r"
        undoButton.target = self
        undoButton.action = #selector(undo(_:))
        undoButton.isEnabled = false
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow(_:)))
        close.keyEquivalent = "\u{1b}"
        statusLabel.font = Theme.smallFont
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [statusLabel, start, undoButton, close])
        buttons.spacing = 8

        for v in [top, scroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    @objc private func insertToken(_ sender: NSMenuItem) {
        guard let (field, token) = sender.representedObject as? (NSTextField, String) else { return }
        field.stringValue += token
        compute()
    }

    @objc private func optionChanged(_ sender: Any?) { compute() }

    func controlTextDidChange(_ obj: Notification) { compute() }

    private static func substring(_ s: String, from: Int?, to: Int?, hasRange: Bool) -> String {
        guard let from else { return s }
        let chars = Array(s)
        let start = max(from - 1, 0)
        let end: Int
        if hasRange {
            end = min(to ?? chars.count, chars.count)
        } else {
            end = min(from, chars.count)
        }
        guard start < end else { return "" }
        return String(chars[start..<end])
    }

    private func expand(_ mask: String, base: String, ext: String, counter: String, parent: String, date: Date) -> String {
        let ns = mask as NSString
        var out = ""
        var last = 0
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        for m in Self.tokenRegex.matches(in: mask, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            let token = ns.substring(with: m.range(at: 1))
            let from = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) : nil
            let hasRange = m.range(at: 3).location != NSNotFound
            let toStr = m.range(at: 4).location != NSNotFound ? ns.substring(with: m.range(at: 4)) : ""
            let to = Int(toStr)
            switch token {
            case "N": out += Self.substring(base, from: from, to: to, hasRange: hasRange)
            case "E": out += Self.substring(ext, from: from, to: to, hasRange: hasRange)
            case "P": out += Self.substring(parent, from: from, to: to, hasRange: hasRange)
            case "C": out += counter
            case "YMD": out += "\(c.year ?? 0)\(two(c.month))\(two(c.day))"
            case "hms": out += "\(two(c.hour))\(two(c.minute))\(two(c.second))"
            case "Y": out += "\(c.year ?? 0)"
            case "M": out += two(c.month)
            case "D": out += two(c.day)
            case "h": out += two(c.hour)
            case "m": out += two(c.minute)
            case "s": out += two(c.second)
            default: out += ns.substring(with: m.range)
            }
        }
        out += ns.substring(from: last)
        return out
    }

    private func applyCase(_ s: String) -> String {
        switch casePopup.indexOfSelectedItem {
        case 1: return s.lowercased()
        case 2: return s.uppercased()
        case 3: return s.prefix(1).uppercased() + s.dropFirst().lowercased()
        case 4: return s.capitalized
        default: return s
        }
    }

    private func compute() {
        let start = Int(counterStart.stringValue) ?? 1
        let step = Int(counterStep.stringValue) ?? 1
        let digits = min(max(Int(counterDigits.stringValue) ?? 1, 1), 12)
        let search = searchField.stringValue
        let replace = replaceField.stringValue
        let useRegex = regexCheck.state == .on
        let caseSensitive = caseCheck.state == .on
        var regex: NSRegularExpression?
        regexInvalid = false
        if useRegex && !search.isEmpty {
            regex = try? NSRegularExpression(pattern: search, options: caseSensitive ? [] : [.caseInsensitive])
            regexInvalid = regex == nil
        }

        newNames = urls.enumerated().map { i, u in
            let item = FileItem.make(u)
            let name = u.lastPathComponent
            let base = item?.baseName ?? name
            let ext = item?.ext ?? ""
            // Typed-in start/step values can be anything; an overflowing counter must not crash the app.
            let (product, o1) = i.multipliedReportingOverflow(by: step)
            let (value, o2) = start.addingReportingOverflow(product)
            let counter = o1 || o2 ? "overflow" : String(format: "%0\(digits)lld", Int64(value))
            let date = item?.modified ?? Date()
            let parent = u.deletingLastPathComponent().lastPathComponent
            let newBase = expand(nameMask.stringValue, base: base, ext: ext, counter: counter, parent: parent, date: date)
            let newExt = expand(extMask.stringValue, base: base, ext: ext, counter: counter, parent: parent, date: date)
            var full = newExt.isEmpty ? newBase : newBase + "." + newExt
            if !search.isEmpty {
                if useRegex {
                    if let regex {
                        full = regex.stringByReplacingMatches(in: full, range: NSRange(location: 0, length: (full as NSString).length),
                                                              withTemplate: replace)
                    }
                } else {
                    full = full.replacingOccurrences(of: search, with: replace, options: caseSensitive ? [] : [.caseInsensitive])
                }
            }
            return applyCase(full)
        }
        let changed = zip(urls, newNames).filter { $0.lastPathComponent != $1 }.count
        statusLabel.stringValue = regexInvalid ? "Invalid regular expression in Search"
                                               : "\(urls.count) file(s), \(changed) will be renamed"
        table.reloadData()
    }

    /// Set by compute() when the regular expression in the Search field doesn't parse.
    private var regexInvalid = false

    /// RENAME_EXCL: fail instead of replacing an existing file.
    private static let renameExclusive: UInt32 = 0x00000004

    @objc private func startRename(_ sender: Any?) {
        compute()
        if regexInvalid {
            Dialogs.error("Nothing was renamed", "The regular expression in the Search field is not valid.")
            return
        }
        var plan: [(from: URL, to: URL)] = []
        for (i, u) in urls.enumerated() where newNames[i] != u.lastPathComponent {
            plan.append((u, u.deletingLastPathComponent().appendingPathComponent(newNames[i])))
        }
        guard !plan.isEmpty else { return }
        let errors = validate(plan)
        if !errors.isEmpty {
            Dialogs.error("Nothing was renamed", errors.prefix(30).joined(separator: "\n"))
            return
        }
        let result = Self.apply(plan)
        undoPairs = result.done.map { ($0.from, $0.to) }
        for pair in result.done {
            if let idx = urls.firstIndex(of: pair.from) { urls[idx] = pair.to }
        }
        undoButton.isEnabled = !undoPairs.isEmpty
        compute()
        completion()
        if !result.errors.isEmpty {
            Dialogs.error("Some files were not renamed", result.errors.prefix(30).joined(separator: "\n"))
        }
    }

    /// Checks the whole batch before anything is touched.
    private func validate(_ plan: [(from: URL, to: URL)]) -> [String] {
        var errors: [String] = []
        let renamedAway = Set(plan.map { $0.from.path.lowercased() })
        var seen: [String: String] = [:]
        for (from, to) in plan {
            let n = to.lastPathComponent
            if n.isEmpty || n.contains("/") || n == "." || n == ".." || n.contains("\0") {
                errors.append("\(from.lastPathComponent): invalid new name \"\(n)\"")
                continue
            }
            if n.utf8.count > 255 {
                errors.append("\(from.lastPathComponent): new name is too long")
                continue
            }
            // Compare case-insensitively: on the default macOS volumes "A" and "a" are the same file.
            let key = to.path.lowercased()
            if let other = seen[key] {
                errors.append("\(from.lastPathComponent) and \(other) would both become \"\(n)\"")
            }
            seen[key] = from.lastPathComponent
            if pathExists(to) && !isSameFile(from, to) && !renamedAway.contains(key) {
                errors.append("\(n): a file with this name already exists")
            }
        }
        return errors
    }

    /// Renames in two phases through unique temporary names, so swaps and chains (a→b, b→c) work.
    /// Never replaces an existing file; anything that fails is moved back to its original name.
    static func apply(_ plan: [(from: URL, to: URL)]) -> (done: [(from: URL, to: URL)], errors: [String]) {
        var errors: [String] = []
        var staged: [(from: URL, temp: URL, to: URL)] = []
        for (from, to) in plan {
            // A visible temporary name: if the app dies between the two phases, the files stay easy to find.
            let temp = from.deletingLastPathComponent().appendingPathComponent("FileAdmiral-renaming-\(UUID().uuidString.prefix(8))")
            if renamex_np(from.path, temp.path, renameExclusive) == 0 {
                staged.append((from, temp, to))
            } else {
                errors.append("\(from.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        }
        var done: [(from: URL, to: URL)] = []
        var failed: [(from: URL, temp: URL)] = []
        for s in staged {
            if renamex_np(s.temp.path, s.to.path, renameExclusive) == 0 {
                done.append((s.from, s.to))
            } else {
                errors.append("\(s.from.lastPathComponent) → \(s.to.lastPathComponent): \(String(cString: strerror(errno)))")
                failed.append((s.from, s.temp))
            }
        }
        for f in failed where renamex_np(f.temp.path, f.from.path, renameExclusive) != 0 {
            errors.append("Could not restore \(f.from.lastPathComponent); it is saved as \(f.temp.path)")
        }
        return (done, errors)
    }

    @objc private func undo(_ sender: Any?) {
        let plan = undoPairs.map { (from: $0.to, to: $0.from) }
        let result = Self.apply(plan)
        for pair in result.done {
            if let idx = urls.firstIndex(of: pair.from) { urls[idx] = pair.to }
        }
        undoPairs.removeAll()
        undoButton.isEnabled = false
        compute()
        completion()
        if !result.errors.isEmpty { Dialogs.error("Undo incomplete", result.errors.joined(separator: "\n")) }
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.close()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { urls.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let id = col.identifier
        let tf = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.font = Theme.font
            t.lineBreakMode = .byTruncatingMiddle
            return t
        }()
        let old = urls[row].lastPathComponent
        if id.rawValue == "old" {
            tf.stringValue = old
            tf.textColor = .labelColor
        } else {
            let n = row < newNames.count ? newNames[row] : old
            tf.stringValue = n
            tf.textColor = n == old ? .secondaryLabelColor : Theme.marked
        }
        return tf
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { Self.openWindows.removeAll { $0 === self } }
    }
}
