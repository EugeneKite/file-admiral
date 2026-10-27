import AppKit
import Quartz

/// Split view that knows whether the user is dragging its divider.
final class PanelSplitView: NSSplitView {
    private(set) var isDraggingDivider = false

    override func mouseDown(with event: NSEvent) {
        // NSSplitView only receives mouse-downs on its dividers; super runs the whole drag loop.
        isDraggingDivider = true
        super.mouseDown(with: event)
        isDraggingDivider = false
    }
}

/// Grey background strip used for the toolbar.
/// Function-key button; in retro themes it draws itself DOS style: "F3" white on black, "View" on cyan.
final class FunctionKeyButton: NSButton {
    let number: String
    let label: String

    init(number: String, label: String, target: AnyObject?, action: Selector) {
        self.number = number
        self.label = label
        super.init(frame: .zero)
        self.title = "\(number) \(label)"
        self.target = target
        self.action = action
        bezelStyle = .smallSquare
        refusesFirstResponder = true
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func applyTheme() {
        isBordered = Theme.current.retro == nil
        font = Theme.font
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let r = Theme.current.retro else { return super.draw(dirtyRect) }
        let font = NSFont.monospacedSystemFont(ofSize: Theme.fontSize + 1, weight: .bold)
        // The key ("F3" / "⌘Q") white on black, then the label on cyan, as on the DOS bar.
        let numText = NSAttributedString(string: number, attributes: [.font: font, .foregroundColor: r.fkeyNumber])
        let numWidth = numText.size().width + 8
        r.fkeyNumberBackground.setFill()
        NSRect(x: 0, y: 0, width: numWidth, height: bounds.height).fill()
        (isHighlighted ? r.fkeyLabelBackground.blended(withFraction: 0.3, of: .white)! : r.fkeyLabelBackground).setFill()
        NSRect(x: numWidth, y: 0, width: bounds.width - numWidth, height: bounds.height).fill()
        let y = (bounds.height - numText.size().height) / 2
        numText.draw(at: NSPoint(x: 4, y: y))
        NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: r.fkeyLabel])
            .draw(at: NSPoint(x: numWidth + 4, y: y))
    }
}

/// Column header cell that uses the retro theme colors (Norton Commander: yellow on blue).
final class ThemedHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let r = Theme.current.retro else { return super.draw(withFrame: cellFrame, in: controlView) }
        r.columnHeaderBackground.setFill()
        cellFrame.fill()
        NSColor.black.withAlphaComponent(0.3).setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY, width: 1, height: cellFrame.height).fill()
        let text = NSAttributedString(string: stringValue, attributes: [.font: NSFont.boldSystemFont(ofSize: Theme.fontSize),
                                                                        .foregroundColor: r.columnHeaderText])
        let size = text.size()
        let x = alignment == .right ? cellFrame.maxX - size.width - 8 : cellFrame.minX + 6
        text.draw(at: NSPoint(x: x, y: cellFrame.midY - size.height / 2))
    }
}

final class BarView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.barBackground.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// Flat toolbar button that shows a rounded background on hover and when "on".
final class ToolbarButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    var isHighlightedState = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .smallSquare
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlightedState || isHighlighted {
            let alpha: CGFloat = isHighlighted ? 0.16 : (isHighlightedState ? 0.12 : 0.08)
            NSColor.black.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSTextFieldDelegate,
    NSSplitViewDelegate, NSMenuDelegate {
    private(set) var left: FilePanel!
    private(set) var right: FilePanel!
    private(set) var active: FilePanel!
    var other: FilePanel { active === left ? right : left }

    var showHidden = UserDefaults.standard.bool(forKey: "showHidden")

    private let split = PanelSplitView()
    /// Left panel share of the split, changed only by the user dragging the divider.
    private var splitRatio = CGFloat(UserDefaults.standard.object(forKey: "splitRatio") as? Double ?? 0.5)
    private var restoringSplit = false
    private let promptLabel = NSTextField(labelWithString: ">")
    private let commandField = NSTextField(string: "")
    private let backgroundButton = NSButton(title: "", target: nil, action: nil)
    private var functionKeyButtons: [FunctionKeyButton] = []
    /// File-operation undo (⌘Z): every action is reversed by moving items back or into the Trash,
    /// so Undo itself can always be redone and never deletes anything permanently.
    let fileUndo = UndoManager()
    private var commandHistory: [String] = UserDefaults.standard.stringArray(forKey: "commandHistory") ?? []
    private var historyIndex = -1
    private var hiddenButton: ToolbarButton?

    private var hotlist: [String] {
        get {
            if let h = UserDefaults.standard.stringArray(forKey: "hotlist") { return h }
            let home = FileManager.default.homeDirectoryForCurrentUser
            return [home.path, home.appendingPathComponent("Desktop").path, home.appendingPathComponent("Documents").path,
                    home.appendingPathComponent("Downloads").path, "/Applications"]
        }
        set { UserDefaults.standard.set(newValue, forKey: "hotlist") }
    }

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "FileAdmiral"
        win.minSize = NSSize(width: 780, height: 420)
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        win.center()
        win.setFrameAutosaveName("MainWindow")
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let toolbar = makeToolbar()
        toolbarView = toolbar
        left = FilePanel(side: .left, controller: self)
        right = FilePanel(side: .right, controller: self)
        active = UserDefaults.standard.string(forKey: "activeSide") == "right" ? right : left

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.delegate = self

        let cmdRow = makeCommandRow()
        let fkeys = makeFunctionKeyBar()
        commandRow = cmdRow
        functionKeyBar = fkeys
        commandRowHeight = cmdRow.heightAnchor.constraint(equalToConstant: 22)
        functionKeyBarHeight = fkeys.heightAnchor.constraint(equalToConstant: 24)

        for v in [toolbar, split, cmdRow, fkeys] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        toolbarTop = toolbar.topAnchor.constraint(equalTo: content.topAnchor)
        toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: showToolbarLabels ? 56 : 36)
        NSLayoutConstraint.activate([
            toolbarHeight,
            toolbarTop,
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 2),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 2),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),

            cmdRow.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 3),
            cmdRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            cmdRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            commandRowHeight,

            fkeys.topAnchor.constraint(equalTo: cmdRow.bottomAnchor, constant: 3),
            fkeys.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 2),
            fkeys.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),
            fkeys.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -3),
            functionKeyBarHeight,
        ])
        left.isActive = active === left
        right.isActive = active === right
        updatePrompt()
        updateTitle()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange(_:)), name: .themeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyLayoutSettings(_:)), name: .settingsChanged, object: nil)
        applyLayoutSettings(nil)
        applyChromeTheme()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.layoutIfNeeded()
        restoreSplit()
        active.activate()
    }

    private struct ToolSpec {
        let symbol: String
        let label: String
        let tip: String
        let action: Selector
        let color: NSColor
    }

    /// Toolbar layout: groups separated by dividers. Icons are literal and every button has a caption.
    private let toolGroups: [[ToolSpec]] = [
        [ToolSpec(symbol: "arrow.clockwise.circle.fill", label: "Refresh", tip: "Reread both panels (⌘R)",
                  action: #selector(refresh(_:)), color: .systemGreen),
         ToolSpec(symbol: "eye.slash", label: "Hidden", tip: "Show / hide hidden files (⌘⇧.)",
                  action: #selector(toggleHidden(_:)), color: .systemGray)],
        [ToolSpec(symbol: "chevron.backward.circle.fill", label: "Back", tip: "Previous folder (⌘[)",
                  action: #selector(goBack(_:)), color: .systemBlue),
         ToolSpec(symbol: "chevron.forward.circle.fill", label: "Forward", tip: "Next folder (⌘])",
                  action: #selector(goForward(_:)), color: .systemBlue),
         ToolSpec(symbol: "arrow.up.circle.fill", label: "Up", tip: "Parent folder (⌫)",
                  action: #selector(goParent(_:)), color: .systemBlue)],
        [ToolSpec(symbol: "checkmark.circle.fill", label: "Select", tip: "Select files by mask, e.g. *.jpg (+)",
                  action: #selector(selectGroup(_:)), color: .systemRed),
         ToolSpec(symbol: "xmark.circle", label: "Unselect", tip: "Unselect files by mask (-)",
                  action: #selector(unselectGroup(_:)), color: .systemRed),
         ToolSpec(symbol: "circle.righthalf.filled", label: "Invert", tip: "Invert selection (*)",
                  action: #selector(invertSelection(_:)), color: .systemRed)],
        [ToolSpec(symbol: "doc.zipper", label: "Zip", tip: "Pack selected files into an archive (⌥F5)",
                  action: #selector(packFiles(_:)), color: .systemBrown),
         ToolSpec(symbol: "shippingbox.and.arrow.backward", label: "Unzip", tip: "Unpack archives (⌥F9)",
                  action: #selector(unpackFiles(_:)), color: .systemBrown)],
        [ToolSpec(symbol: "magnifyingglass", label: "Find", tip: "Find files (⌥F7 / ⌘F)",
                  action: #selector(searchFiles(_:)), color: .systemIndigo),
         ToolSpec(symbol: "character.cursor.ibeam", label: "Rename", tip: "Multi-Rename Tool (⌘M)",
                  action: #selector(multiRename(_:)), color: .systemOrange),
         ToolSpec(symbol: "equal.square", label: "Compare", tip: "Compare folders: marks newer and missing files (⌘⇧C)",
                  action: #selector(compareDirectories(_:)), color: Theme.toolTeal),
         ToolSpec(symbol: "arrow.left.arrow.right.square", label: "Swap", tip: "Swap left and right panels (⌘U)",
                  action: #selector(swapPanels(_:)), color: Theme.toolTeal),
         ToolSpec(symbol: "rectangle.righthalf.inset.filled.arrow.right", label: "Mirror", tip: "Open the same folder in the other panel (⌘=)",
                  action: #selector(targetEqualsSource(_:)), color: Theme.toolTeal)],
        [ToolSpec(symbol: "network", label: "Connect", tip: "Connect to an FTP / SFTP server (⌘K)",
                  action: #selector(showConnections(_:)), color: .systemBlue),
         ToolSpec(symbol: "plus.rectangle.on.rectangle", label: "New Tab", tip: "Open a new tab in the active panel (⌘T)",
                  action: #selector(newTab(_:)), color: .systemPurple),
         ToolSpec(symbol: "star.fill", label: "Favorites", tip: "Favorite folders / directory hotlist (⌘D)",
                  action: #selector(showHotlist(_:)), color: .systemYellow),
         ToolSpec(symbol: "terminal.fill", label: "Terminal", tip: "Open Terminal in this folder (⌥⌘T)",
                  action: #selector(openTerminal(_:)), color: .darkGray),
         ToolSpec(symbol: "folder.fill", label: "Finder", tip: "Show in Finder (⌥⌘R)",
                  action: #selector(revealInFinder(_:)), color: .systemBlue),
         ToolSpec(symbol: "square.grid.2x2", label: "Thumbs", tip: "Thumbnails / list view (⌃⇧F1)",
                  action: #selector(toggleThumbnails(_:)), color: .systemIndigo),
         ToolSpec(symbol: "rectangle.righthalf.inset.filled", label: "Quick View",
                  tip: "Preview the file under the cursor in the other panel (⌃Q)",
                  action: #selector(toggleQuickView(_:)), color: .systemIndigo),
         ToolSpec(symbol: "eye.circle.fill", label: "Preview", tip: "Quick Look preview (⌘Y)",
                  action: #selector(quickLook(_:)), color: .systemGray)],
    ]

    private let toolbarStack = NSStackView()
    private var toolbarHeight: NSLayoutConstraint!
    private var toolbarTop: NSLayoutConstraint!
    private var toolbarView: NSView!
    private var commandRow: NSView!
    private var commandRowHeight: NSLayoutConstraint!
    private var functionKeyBar: NSView!
    private var functionKeyBarHeight: NSLayoutConstraint!
    private var showToolbarLabels: Bool {
        get { UserDefaults.standard.object(forKey: "toolbarLabels") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "toolbarLabels") }
    }

    private func toolImage(_ symbol: String, _ color: NSColor, _ desc: String) -> NSImage? {
        // Filled circle symbols become solid colored badges with a white glyph; others are drawn in the color.
        var colors: [NSColor] = symbol.contains("circle.fill") ? [.white, color] : [color]
        if Theme.current.retro != nil {
            // DOS look: black icons on the cyan bar; round badges become black discs with a cyan symbol.
            colors = symbol.contains("circle.fill") ? [Theme.current.barBackground, .black] : [.black]
        }
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)?
            .withSymbolConfiguration(config) else { return nil }
        // Draw the symbol on a fixed, padded canvas: buttons place the image flush with their top edge,
        // which clips round badges, and symbols of different shapes would otherwise sit at uneven heights.
        let canvas = NSSize(width: 26, height: 26)
        let padded = NSImage(size: canvas, flipped: false) { rect in
            let s = symbolImage.size
            symbolImage.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2,
                                        width: s.width, height: s.height))
            return true
        }
        padded.accessibilityDescription = desc
        return padded
    }

    private func toolButton(_ spec: ToolSpec) -> NSButton {
        let b = ToolbarButton()
        b.target = self
        b.action = spec.action
        b.image = toolImage(spec.symbol, spec.color, spec.label)
        b.toolTip = spec.tip
        if showToolbarLabels {
            b.title = spec.label
            b.imagePosition = .imageAbove
            b.font = .systemFont(ofSize: 10)
            // Fixed width per button (label plus padding) so the bar lays out evenly and overflow can be computed.
            let textWidth = ceil((spec.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width)
            b.widthAnchor.constraint(equalToConstant: max(56, textWidth + 16)).isActive = true
            b.heightAnchor.constraint(equalToConstant: 48).isActive = true
        } else {
            b.title = ""
            b.imagePosition = .imageOnly
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        if spec.action == #selector(toggleHidden(_:)) { hiddenButton = b }
        return b
    }

    private func makeToolbar() -> NSView {
        let bar = BarView()
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 4
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(toolbarStack)
        overflowButton.target = self
        overflowButton.action = #selector(showToolbarOverflow(_:))
        overflowButton.toolTip = "More commands"
        overflowButton.imagePosition = .imageOnly
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        overflowButton.isHidden = true
        bar.addSubview(overflowButton)
        NSLayoutConstraint.activate([
            toolbarStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Self.toolbarMargin),
            toolbarStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            overflowButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Self.toolbarMargin),
            overflowButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            overflowButton.widthAnchor.constraint(equalToConstant: Self.overflowWidth),
            overflowButton.heightAnchor.constraint(equalToConstant: 30),
        ])
        bar.onLayout = { [weak self] in self?.updateToolbarOverflow() }
        let menu = NSMenu()
        let labels = NSMenuItem(title: "Show Labels", action: #selector(toggleToolbarLabels(_:)), keyEquivalent: "")
        labels.target = self
        menu.addItem(labels)
        bar.menu = menu
        populateToolbar()
        return bar
    }

    private func populateToolbar() {
        toolbarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (gi, group) in toolGroups.enumerated() {
            if gi > 0 {
                let sep = NSBox()
                sep.boxType = .separator
                sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
                sep.heightAnchor.constraint(equalToConstant: showToolbarLabels ? 34 : 22).isActive = true
                toolbarStack.addArrangedSubview(sep)
                toolbarStack.setCustomSpacing(Self.separatorSpacing, after: toolbarStack.arrangedSubviews[toolbarStack.arrangedSubviews.count - 2])
                toolbarStack.setCustomSpacing(Self.separatorSpacing, after: sep)
            }
            for spec in group { toolbarStack.addArrangedSubview(toolButton(spec)) }
        }
        let toolbarPlugins = PluginManager.shared.commandPlugins.filter(\.toolbar)
        if !toolbarPlugins.isEmpty {
            let sep = NSBox()
            sep.boxType = .separator
            sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
            sep.heightAnchor.constraint(equalToConstant: showToolbarLabels ? 34 : 22).isActive = true
            toolbarStack.setCustomSpacing(Self.separatorSpacing, after: toolbarStack.arrangedSubviews[toolbarStack.arrangedSubviews.count - 1])
            toolbarStack.addArrangedSubview(sep)
            toolbarStack.setCustomSpacing(Self.separatorSpacing, after: sep)
            for p in toolbarPlugins {
                let label = p.name.count > 12 ? String(p.name.prefix(11)) + "…" : p.name
                let b = toolButton(ToolSpec(symbol: p.icon, label: label, tip: p.name + (p.description.isEmpty ? "" : " — " + p.description),
                                            action: #selector(runPlugin(_:)), color: .systemPurple))
                b.identifier = NSUserInterfaceItemIdentifier(p.id)
                if b.image == nil { b.image = toolImage("puzzlepiece.extension", .systemPurple, p.name) }
                toolbarStack.addArrangedSubview(b)
            }
        }
        toolbarHeight?.constant = Settings.showToolbar ? (showToolbarLabels ? 56 : 36) : 0
        overflowButton.image = toolImage("chevron.right.2", .secondaryLabelColor, "More commands")
        updateHiddenButton()
        if functionKeyBarHeight != nil { applyChromeTheme() }
        updateToolbarOverflow()
    }

    private static let toolbarMargin: CGFloat = 8
    private static let separatorSpacing: CGFloat = 10
    private static let overflowWidth: CGFloat = 30
    private let overflowButton = ToolbarButton()

    /// Hides the toolbar items that don't fit the window width; they are offered in the » menu instead.
    private func updateToolbarOverflow() {
        guard let bar = toolbarView else { return }
        let items = toolbarStack.arrangedSubviews
        let widths = items.map { $0.fittingSize.width }
        func gap(after i: Int) -> CGFloat {
            let custom = toolbarStack.customSpacing(after: items[i])
            return custom == NSStackView.useDefaultSpacing ? toolbarStack.spacing : custom
        }
        let available = bar.bounds.width - 2 * Self.toolbarMargin
        let total = widths.enumerated().reduce(CGFloat(0)) { $0 + $1.element + ($1.offset > 0 ? gap(after: $1.offset - 1) : 0) }
        var visible = items.count
        if total > available {
            let room = available - Self.overflowWidth - Self.separatorSpacing
            var used: CGFloat = 0
            visible = 0
            for i in items.indices {
                let w = widths[i] + (i > 0 ? gap(after: i - 1) : 0)
                if used + w > room { break }
                used += w
                visible = i + 1
            }
            // Don't end the visible part with a separator.
            while visible > 0, items[visible - 1] is NSBox { visible -= 1 }
        }
        for (i, v) in items.enumerated() where v.isHidden != (i >= visible) { v.isHidden = i >= visible }
        let overflow = visible < items.count
        if overflowButton.isHidden == overflow { overflowButton.isHidden = !overflow }
    }

    /// Number of toolbar commands currently moved into the » menu (for tests).
    var toolbarOverflowCount: Int {
        overflowButton.isHidden ? 0 : toolbarStack.arrangedSubviews.filter { $0.isHidden && !($0 is NSBox) }.count
    }

    @objc private func showToolbarOverflow(_ sender: Any?) {
        let menu = NSMenu()
        for v in toolbarStack.arrangedSubviews where v.isHidden {
            if v is NSBox {
                if !menu.items.isEmpty && menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            guard let b = v as? NSButton else { continue }
            let item = NSMenuItem(title: b.title.isEmpty ? (b.image?.accessibilityDescription ?? b.toolTip ?? "") : b.title,
                                  action: b.action, keyEquivalent: "")
            item.target = b.target
            item.toolTip = b.toolTip
            item.representedObject = b.identifier?.rawValue // plugin id, used by runPlugin
            if let image = b.image?.copy() as? NSImage {
                image.size = NSSize(width: 18, height: 18)
                item.image = image
            }
            if (b as? ToolbarButton)?.isHighlightedState == true { item.state = .on }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflowButton.bounds.height + 2), in: overflowButton)
    }

    @objc func toggleToolbarLabels(_ sender: Any?) {
        showToolbarLabels.toggle()
        populateToolbar()
    }

    private func updateHiddenButton() {
        guard let b = hiddenButton else { return }
        b.image = toolImage(showHidden ? "eye" : "eye.slash", showHidden ? .systemBlue : .systemGray, "Hidden")
        b.isHighlightedState = showHidden
    }

    private func makeCommandRow() -> NSView {
        promptLabel.alignment = .right
        promptLabel.lineBreakMode = .byTruncatingHead
        promptLabel.font = Theme.font
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        promptLabel.setContentHuggingPriority(.required, for: .horizontal)
        commandField.font = Theme.font
        commandField.delegate = self
        commandField.placeholderString = "command line — Enter runs in a shell, \"cd path\" changes directory"
        commandField.cell?.usesSingleLineMode = true
        commandField.cell?.isScrollable = true
        commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        backgroundButton.bezelStyle = .recessed
        backgroundButton.controlSize = .small
        backgroundButton.target = self
        backgroundButton.action = #selector(showBackgroundOperations(_:))
        backgroundButton.isHidden = true
        backgroundButton.toolTip = "Show background operations"
        NotificationCenter.default.addObserver(self, selector: #selector(backgroundJobsChanged(_:)), name: .backgroundJobsChanged,
                                               object: nil)
        let row = NSStackView(views: [promptLabel, commandField, backgroundButton])
        row.orientation = .horizontal
        row.spacing = 4
        promptLabel.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.45).isActive = true
        return row
    }

    private func makeFunctionKeyBar() -> NSView {
        let specs: [(String, Selector, AnyObject)] = [
            ("F2 Rename", #selector(renameFile(_:)), self),
            ("F3 View", #selector(viewFile(_:)), self),
            ("F4 Edit", #selector(editFile(_:)), self),
            ("F5 Copy", #selector(copyFiles(_:)), self),
            ("F6 Move", #selector(moveFiles(_:)), self),
            ("F7 NewFolder", #selector(makeDirectory(_:)), self),
            ("F8 Delete", #selector(deleteToTrash(_:)), self),
            ("⌘Q Exit", #selector(NSApplication.terminate(_:)), NSApp),
        ]
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        for (title, sel, target) in specs {
            let parts = title.split(separator: " ", maxSplits: 1).map(String.init)
            let b = FunctionKeyButton(number: parts[0], label: parts.count > 1 ? parts[1] : "", target: target, action: sel)
            functionKeyButtons.append(b)
            stack.addArrangedSubview(b)
        }
        return stack
    }

    private func updatePrompt() {
        guard let active else { return }
        promptLabel.stringValue = active.currentURL.path + ">"
    }

    private func updateTitle() {
        guard let active else { return }
        window?.title = "FileAdmiral — \(active.currentURL.abbreviatedPath)"
    }

    // MARK: - Split view

    private var splitAvailableWidth: CGFloat { split.bounds.width - split.dividerThickness }

    private var restoreAttempts = 0

    private func restoreSplit() {
        guard splitAvailableWidth > 400 else { return }
        let position = min(max((splitAvailableWidth * splitRatio).rounded(), 200), splitAvailableWidth - 200)
        restoringSplit = true
        split.setPosition(position, ofDividerAt: 0)
        restoringSplit = false
    }

    func windowWillStartLiveResize(_ notification: Notification) { restoreAttempts = 0 }

    /// Only the user moves the divider: a drag updates the remembered ratio, any other change
    /// (layout passes caused by long names, tabs, etc.) is reverted. Window resizing keeps the ratio.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !restoringSplit, splitAvailableWidth > 0, let first = split.arrangedSubviews.first else { return }
        let current = first.frame.width / splitAvailableWidth
        if split.isDraggingDivider {
            splitRatio = min(max(current, 0.05), 0.95)
            restoreAttempts = 0
            return
        }
        // Restore at most a couple of times in a row: if layout can't honor the position
        // (window too narrow), accept what it gives instead of fighting it forever.
        if abs(current - splitRatio) * splitAvailableWidth >= 1 && restoreAttempts < 2 {
            restoreAttempts += 1
            DispatchQueue.main.async { [weak self] in self?.restoreSplit() }
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 200)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 200)
    }

    // MARK: - Panel coordination

    func setActive(_ p: FilePanel) {
        // Moving into the Quick View panel ends Quick View (as in TC).
        if let qv = quickViewPanel, qv === p {
            qv.hideQuickView()
            quickViewPanel = nil
        }
        active = p
        left.isActive = p === left
        right.isActive = p === right
        updatePrompt()
        updateTitle()
    }

    func panelDidNavigate(_ p: FilePanel) {
        if p === active {
            updatePrompt()
            updateTitle()
        }
    }

    // MARK: - Views, Quick View, Share

    /// The panel currently showing a Quick View preview (TC Ctrl+Q), if any.
    private(set) weak var quickViewPanel: FilePanel?
    private var quickViewWork: DispatchWorkItem?

    @objc func toggleQuickView(_ sender: Any?) {
        if let p = quickViewPanel {
            p.hideQuickView()
            quickViewPanel = nil
        } else {
            let target = other
            quickViewPanel = target
            target.showQuickView(active.cursorItem)
        }
    }

    /// Called when the cursor moves in a panel: keeps the Quick View preview in step.
    func cursorDidMove(in panel: FilePanel) {
        guard let qv = quickViewPanel, panel === active, qv !== panel else { return }
        quickViewWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let panel, self?.quickViewPanel === qv else { return }
            qv.showQuickView(panel.cursorItem)
        }
        quickViewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @objc func showDetailsView(_ sender: Any?) { active.setViewMode(.details) }
    @objc func showThumbnailsView(_ sender: Any?) { active.setViewMode(.thumbnails) }
    @objc func toggleFolderTree(_ sender: Any?) {
        if active.viewMode == .tree { active.leaveTree(openingFolder: nil) } else { active.setViewMode(.tree); active.activate() }
    }

    @objc func toggleThumbnails(_ sender: Any?) {
        active.setViewMode(active.viewMode == .thumbnails ? .details : .thumbnails)
    }

    @objc func chooseThumbnailSize(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let size = Settings.ThumbnailSize(rawValue: raw) {
            Settings.thumbnailSize = size
            left.reloadAllViews()
            right.reloadAllViews()
        }
    }

    /// Share sheet (AirDrop, Mail, Messages, Notes…) for the selected files.
    @objc func shareFiles(_ sender: Any?) {
        if blockedOnRemote("Share") { return }
        let urls = active.operationItems.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        let picker = NSSharingServicePicker(items: urls)
        let view = active.focusView
        var rect = NSRect(x: 0, y: 0, width: 10, height: 10)
        if view === active.tableView, active.tableView.selectedRow >= 0 {
            rect = active.tableView.rect(ofRow: active.tableView.selectedRow)
        } else if view === active.grid, let ip = active.grid.selectionIndexPaths.first,
                  let item = active.grid.item(at: ip) {
            rect = item.view.frame
        }
        picker.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func switchPanel() {
        other.activate()
    }

    func saveState() {
        left.saveState()
        right.saveState()
        let d = UserDefaults.standard
        d.set(active === right ? "right" : "left", forKey: "activeSide")
        d.set(showHidden, forKey: "showHidden")
        d.set(Array(commandHistory.prefix(50)), forKey: "commandHistory")
        d.set(Double(splitRatio), forKey: "splitRatio")
    }

    /// In full screen with "always show menu bar", the menu bar is drawn over the top of the window.
    /// Push the toolbar below it so the icons aren't covered.
    private func updateToolbarInset() {
        guard toolbarTop != nil, let w = window, let content = w.contentView, let screen = w.screen else { return }
        var inset: CGFloat = 0
        if w.styleMask.contains(.fullScreen) {
            let contentTop = w.convertToScreen(content.convert(content.bounds, to: nil)).maxY
            let menuBarHeight = max(screen.safeAreaInsets.top, NSApp.mainMenu?.menuBarHeight ?? 0, 24)
            let overlap = contentTop - (screen.frame.maxY - menuBarHeight)
            inset = max(0, overlap) + 4
        }
        if toolbarTop.constant != inset { toolbarTop.constant = inset }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { updateToolbarInset() }
    func windowDidExitFullScreen(_ notification: Notification) { updateToolbarInset() }
    func windowDidResize(_ notification: Notification) {
        restoreAttempts = 0
        updateToolbarInset()
    }
    func windowDidChangeScreen(_ notification: Notification) { updateToolbarInset() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { fileUndo }

    @objc func showBackgroundOperations(_ sender: Any?) { BackgroundWindowController.show() }

    /// TC "Compare by content": two marked files, or the files under the cursor in both panels.
    @objc func compareFiles(_ sender: Any?) {
        if blockedOnRemote("Compare by Content") { return }
        let marked = active.items.filter { active.marked.contains($0.name) && !$0.isDirectory }
        var pair: (URL, URL)?
        if marked.count == 2 {
            pair = (marked[0].url, marked[1].url)
        } else if let a = active.cursorItem, !a.isDirectory, !other.isRemote {
            if let b = other.cursorItem, !b.isDirectory {
                pair = (a.url, b.url)
            } else if let same = other.items.first(where: { $0.name == a.name && !$0.isDirectory }) {
                pair = (a.url, same.url)
            }
        }
        guard let (a, b) = pair else {
            Dialogs.info("Compare by Content", "Mark two files, or put the cursor on a file in each panel.")
            return
        }
        let first = active === left ? a : b, second = active === left ? b : a
        DiffWindowController.compare(marked.count == 2 ? a : first, marked.count == 2 ? b : second)
    }

    // MARK: - Finder tags

    /// Tags submenu for the selected files: color tags, other tags in this folder, new tag, remove all.
    func tagsMenu() -> NSMenu {
        let m = NSMenu(title: "Tags")
        let selected = active.operationItems
        func state(_ name: String) -> NSControl.StateValue {
            let n = selected.filter { $0.tags.contains { $0.name == name } }.count
            return n == 0 ? .off : (n == selected.count ? .on : .mixed)
        }
        for (i, tag) in FinderTags.standard.enumerated() {
            let mi = NSMenuItem(title: tag.name, action: #selector(toggleTag(_:)), keyEquivalent: "\(i + 1)")
            mi.keyEquivalentModifierMask = [.control]
            mi.image = FinderTags.dot(tag.color)
            mi.representedObject = tag.name
            mi.state = state(tag.name)
            mi.target = self
            m.addItem(mi)
        }
        let standardNames = Set(FinderTags.standard.map(\.name))
        let others = Set(active.items.flatMap(\.tags)).filter { !standardNames.contains($0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !others.isEmpty {
            m.addItem(.separator())
            for tag in others {
                let mi = NSMenuItem(title: tag.name, action: #selector(toggleTag(_:)), keyEquivalent: "")
                mi.image = FinderTags.dot(tag.color)
                mi.representedObject = tag.name
                mi.state = state(tag.name)
                mi.target = self
                m.addItem(mi)
            }
        }
        m.addItem(.separator())
        for (title, sel) in [("New Tag…", #selector(newTag(_:))), ("Remove All Tags", #selector(removeAllTags(_:)))] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            m.addItem(mi)
        }
        return m
    }

    private func applyTagChange(_ change: ([URL]) throws -> Void) {
        if blockedOnRemote("Tags") { return }
        let items = active.operationItems
        guard !items.isEmpty else { NSSound.beep(); return }
        do {
            try change(items.map(\.url))
        } catch {
            Dialogs.error("Cannot change tags", error.localizedDescription)
        }
        active.reload()
    }

    @objc func toggleTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let tag = FinderTags.standard.first { $0.name == name } ?? FinderTag(name: name, colorIndex: 0)
        applyTagChange { try FinderTags.toggle(tag, on: $0) }
    }

    /// ⌃1…⌃7: toggle the n-th color tag (Finder's menu order) on the selected files.
    func toggleStandardTag(_ index: Int) {
        let tags = FinderTags.standard
        guard index >= 0, index < tags.count else { return }
        applyTagChange { try FinderTags.toggle(tags[index], on: $0) }
    }

    @objc func newTag(_ sender: Any?) {
        guard let name = Dialogs.prompt(title: "New Tag", message: "Tag name:", defaultValue: "", okTitle: "Add"),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let tag = FinderTag(name: name.trimmingCharacters(in: .whitespaces), colorIndex: 0)
        applyTagChange { urls in
            for u in urls {
                var tags = FinderTags.read(u.path)
                if !tags.contains(where: { $0.name == tag.name }) { tags.append(tag) }
                try FinderTags.write(u, tags)
            }
        }
    }

    @objc func removeAllTags(_ sender: Any?) {
        applyTagChange { urls in for u in urls { try FinderTags.write(u, []) } }
    }

    @objc func selectByTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        active.setMarked(Set(active.items.filter { $0.tags.contains { $0.name == name } }.map(\.name)))
    }

    /// Fills the Files › Tags and Mark › Select by Tag submenus when they open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.title == "Select by Tag" {
            let tags = Set(active.items.flatMap(\.tags)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if tags.isEmpty {
                menu.addItem(NSMenuItem(title: "No tagged files here", action: nil, keyEquivalent: ""))
            }
            for tag in tags {
                let mi = NSMenuItem(title: tag.name, action: #selector(selectByTag(_:)), keyEquivalent: "")
                mi.image = FinderTags.dot(tag.color)
                mi.representedObject = tag.name
                mi.target = self
                menu.addItem(mi)
            }
        } else {
            for item in tagsMenu().items {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
        }
    }

    @objc func findDuplicates(_ sender: Any?) {
        if blockedOnRemote("Find Duplicates") { return }
        DuplicatesWindowController.show(controller: self, folder: active.currentURL)
    }

    @objc func showDiskUsage(_ sender: Any?) {
        if blockedOnRemote("Disk Usage") { return }
        let folder = active.cursorItem.flatMap { $0.isFolder && !$0.isParent ? $0.url : nil } ?? active.currentURL
        DiskUsageWindowController.show(controller: self, folder: folder)
    }

    @objc func synchronizeFolders(_ sender: Any?) {
        guard !left.isRemote, !right.isRemote else {
            Dialogs.info("Synchronize", "Synchronizing works between two local folders.")
            return
        }
        SyncWindowController.show(controller: self, left: left.currentURL, right: right.currentURL)
    }

    @objc private func backgroundJobsChanged(_ n: Notification) {
        let count = BackgroundQueue.shared.entries.count
        backgroundButton.isHidden = count == 0
        backgroundButton.title = "⏳ \(count) in background"
        if count == 0 { refreshBoth() }
    }

    // MARK: - Undo

    /// Registers an undo that moves each item from `pairs.from` back to `pairs.to`.
    func registerUndoMove(_ pairs: [(from: URL, to: URL)], name: String) {
        guard !pairs.isEmpty else { return }
        fileUndo.registerUndo(withTarget: self) { target in
            target.performMove(pairs, name: name)
        }
        fileUndo.setActionName(name)
    }

    /// Registers an undo that moves the given items to the Trash (they can be put back with Redo).
    func registerUndoTrash(_ urls: [URL], name: String) {
        guard !urls.isEmpty else { return }
        fileUndo.registerUndo(withTarget: self) { target in
            target.performTrash(urls, name: name)
        }
        fileUndo.setActionName(name)
    }

    private func performMove(_ pairs: [(from: URL, to: URL)], name: String) {
        var done: [(from: URL, to: URL)] = []
        var problems: [String] = []
        for (from, to) in pairs {
            if pathExists(to) && !isSameFile(from, to) {
                problems.append("\(to.path) already exists")
                continue
            }
            try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if renamex_np(from.path, to.path, 0x4) == 0 || (isSameFile(from, to) && rename(from.path, to.path) == 0) {
                done.append((from, to))
            } else if errno == EXDEV {
                do {
                    try FileManager.default.moveItem(at: from, to: to)
                    done.append((from, to))
                } catch {
                    problems.append("\(from.lastPathComponent): \(error.localizedDescription)")
                }
            } else {
                problems.append("\(from.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        }
        // The opposite action, so Redo works.
        registerUndoMove(done.map { ($0.to, $0.from) }, name: name)
        refreshBoth()
        if !problems.isEmpty { Dialogs.error("Could not undo everything", problems.prefix(20).joined(separator: "\n")) }
    }

    private func performTrash(_ urls: [URL], name: String) {
        var restored: [(from: URL, to: URL)] = []
        var problems: [String] = []
        for u in urls where pathExists(u) {
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: u, resultingItemURL: &result)
                if let r = result as URL? { restored.append((r, u)) }
            } catch {
                problems.append("\(u.lastPathComponent): \(error.localizedDescription)")
            }
        }
        registerUndoMove(restored, name: name)
        refreshBoth()
        if !problems.isEmpty { Dialogs.error("Could not undo everything", problems.prefix(20).joined(separator: "\n")) }
    }

    func windowWillClose(_ notification: Notification) {
        saveState()
    }

    private func refreshBoth() {
        left.reload()
        right.reload()
    }

    private func describe(_ items: [FileItem]) -> String {
        if items.count == 1 { return "\"\(items[0].name)\"" }
        let dirs = items.filter(\.isFolder).count
        let files = items.count - dirs
        var parts: [String] = []
        if files > 0 { parts.append("\(files) file(s)") }
        if dirs > 0 { parts.append("\(dirs) folder(s)") }
        return parts.joined(separator: " and ")
    }

    private func resolve(_ text: String, relativeTo base: URL) -> URL {
        // Only line breaks are trimmed: leading/trailing spaces can be part of a file name.
        var t = (text.trimmingCharacters(in: .newlines) as NSString).expandingTildeInPath
        if t.trimmingCharacters(in: .whitespaces).isEmpty { return base }
        if !t.hasPrefix("/") { t = base.path + "/" + t }
        return URL(fileURLWithPath: t).standardizedFileURL
    }

    // MARK: - Command line

    var commandLineText: String { commandField.stringValue }

    func insertIntoCommandLine(_ s: String) {
        let quoted = s.contains(" ") || s.contains("'") ? "\"\(s)\"" : s
        var cur = commandField.stringValue
        if !cur.isEmpty && !cur.hasSuffix(" ") { cur += " " }
        commandField.stringValue = cur + quoted + " "
    }

    /// Command-line typing mode: a character typed in the panel is appended to the command line.
    func typeIntoCommandLine(_ s: String) {
        commandField.stringValue += s
    }

    func deleteCommandLineCharacter() {
        if !commandField.stringValue.isEmpty { commandField.stringValue.removeLast() }
    }

    func clearCommandLine() {
        commandField.stringValue = ""
        historyIndex = -1
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === commandField else { return false }
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            executeCommandLine(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            clearCommandLine()
            active.activate()
            return true
        case #selector(NSResponder.insertTab(_:)):
            active.activate()
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard !commandHistory.isEmpty else { return true }
            historyIndex = min(historyIndex + 1, commandHistory.count - 1)
            commandField.stringValue = commandHistory[historyIndex]
            textView.moveToEndOfDocument(nil)
            return true
        case #selector(NSResponder.moveDown(_:)):
            historyIndex = max(historyIndex - 1, -1)
            commandField.stringValue = historyIndex >= 0 ? commandHistory[historyIndex] : ""
            textView.moveToEndOfDocument(nil)
            return true
        default:
            return false
        }
    }

    @objc func executeCommandLine(_ sender: Any?) {
        let cmd = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        clearCommandLine()
        active.activate()
        guard !cmd.isEmpty else { return }
        commandHistory.removeAll { $0 == cmd }
        commandHistory.insert(cmd, at: 0)

        if let fs = active.remote {
            // On an FTP/SFTP panel only "cd" is understood; shell commands would run locally.
            guard cmd == "cd" || cmd.hasPrefix("cd ") else {
                Dialogs.info("Command line", "Shell commands run on this Mac, so they are not available on FTP/SFTP panels. Use \"cd path\" to change the remote folder.")
                return
            }
            var arg = cmd == "cd" ? fs.initialPath : String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if arg.count >= 2, arg.hasPrefix("\""), arg.hasSuffix("\"") { arg = String(arg.dropFirst().dropLast()) }
            if arg == ".." { active.goParent(); return }
            let path = arg.hasPrefix("/") ? arg : RemotePath.join(active.remotePath, arg)
            active.navigateRemote(fs, path: (path as NSString).standardizingPath, select: nil, recordHistory: true)
            return
        }

        if cmd == "cd" || cmd == "cd ~" {
            active.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        if cmd.hasPrefix("cd ") {
            var arg = String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if arg.count >= 2, (arg.hasPrefix("\"") && arg.hasSuffix("\"")) || (arg.hasPrefix("'") && arg.hasSuffix("'")) {
                arg = String(arg.dropFirst().dropLast())
            }
            let url = resolve(arg, relativeTo: active.currentURL)
            if url == active.currentURL.deletingLastPathComponent().standardizedFileURL {
                active.goParent()
            } else {
                active.navigate(to: url)
            }
            return
        }
        let cwd = active.currentURL
        TaskRunner.run(title: "Running command", executable: "/bin/zsh", arguments: ["-lc", cmd], cwd: cwd, window: window) {
            [weak self] status, output in
            self?.refreshBoth()
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty || status != 0 {
                ViewerWindowController.show(text: output + (status != 0 ? "\n[exit code \(status)]" : ""),
                                            title: "Output - \(cmd)")
            }
        }
    }

    // MARK: - Menu validation

    /// Menu commands that make sense whichever window is in front.
    private static let globalActions: Set<Selector> = [
        #selector(showSettings(_:)), #selector(showConnections(_:)), #selector(showBackgroundOperations(_:)), #selector(chooseColorScheme(_:)), #selector(biggerFont(_:)), #selector(smallerFont(_:)),
        #selector(defaultFontSize(_:)), #selector(showPermissions(_:)), #selector(showKeyboardHelp(_:)),
        #selector(chooseEditor(_:)), #selector(toggleToolbarLabels(_:)), #selector(openPluginsFolder(_:)),
        #selector(reloadPluginsAction(_:)), #selector(installSamplePlugins(_:)), #selector(showPluginHelp(_:)),
    ]

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Panel commands only while the main window is in front: F8 in the Lister or Cmd+W in
        // Find Files must not act on the panels (AppKit would otherwise route them here too).
        if let action = item.action, !Self.globalActions.contains(action),
           let key = NSApp.keyWindow, key !== window {
            return false
        }
        switch item.action {
        case #selector(toggleHidden(_:)):
            item.state = showHidden ? .on : .off
        case #selector(sortByName(_:)):
            item.state = active.sortKey == .name ? .on : .off
        case #selector(sortByExt(_:)):
            item.state = active.sortKey == .ext ? .on : .off
        case #selector(sortBySize(_:)):
            item.state = active.sortKey == .size ? .on : .off
        case #selector(sortByDate(_:)):
            item.state = active.sortKey == .date ? .on : .off
        case #selector(reverseSort(_:)):
            item.state = active.ascending ? .off : .on
        case #selector(chooseColorScheme(_:)):
            item.state = (item.representedObject as? String) == Theme.schemeName ? .on : .off
        case #selector(showDetailsView(_:)):
            item.state = active.viewMode == .details ? .on : .off
        case #selector(showThumbnailsView(_:)):
            item.state = active.viewMode == .thumbnails ? .on : .off
        case #selector(toggleFolderTree(_:)):
            item.state = active.viewMode == .tree ? .on : .off
        case #selector(toggleQuickView(_:)):
            item.state = quickViewPanel != nil ? .on : .off
        case #selector(chooseThumbnailSize(_:)):
            item.state = (item.representedObject as? String) == Settings.thumbnailSize.rawValue ? .on : .off
        case #selector(toggleToolbarLabels(_:)):
            item.state = showToolbarLabels ? .on : .off
        case #selector(closeTab(_:)):
            return true // with one tab it beeps; Cmd+W must not fall through to closing the main window
        default:
            break
        }
        return true
    }

    // MARK: - File commands

    @objc func refresh(_ sender: Any?) {
        active.reload()
        other.reload()
    }

    @objc func viewFile(_ sender: Any?) {
        guard let it = active.cursorItem, !it.isParent else { return }
        if active.isRemote {
            if it.isDirectory { NSSound.beep() } else { viewRemoteFile(it) }
            return
        }
        if it.isDirectory {
            active.calculateSize(of: it)
            return
        }
        ViewerWindowController.show(url: it.url)
    }

    @objc func editFile(_ sender: Any?) {
        guard let it = active.cursorItem, !it.isParent, !it.isFolder else { NSSound.beep(); return }
        if active.isRemote {
            editRemoteFile(it)
            return
        }
        openInEditor(it.url)
    }

    func openInEditorForRemote(_ url: URL) { openInEditor(url) }

    private func openInEditor(_ url: URL) {
        let editor = UserDefaults.standard.string(forKey: "editorApp")
        if let editor, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-t", url.path]
            try? p.run()
        }
    }

    @objc func chooseEditor(_ sender: Any?) {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.message = "Choose the application used by F4 Edit"
        if p.runModal() == .OK, let u = p.url, let id = Bundle(url: u)?.bundleIdentifier {
            UserDefaults.standard.set(id, forKey: "editorApp")
        }
    }

    @objc func newFile(_ sender: Any?) {
        if blockedOnRemote("Creating a new file") { return }
        guard let name = Dialogs.prompt(title: "New file", message: "Create and edit a new file:", defaultValue: "new.txt",
                                        selectBaseName: true), !name.isEmpty else { return }
        let url = resolve(name, relativeTo: active.currentURL)
        if !pathExists(url) {
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                Dialogs.error("Cannot create file", url.path)
                return
            }
            registerUndoTrash([url], name: "New File")
        }
        if url.deletingLastPathComponent().standardizedFileURL == active.currentURL.standardizedFileURL {
            active.reload(selectName: url.lastPathComponent)
        }
        openInEditor(url)
    }

    @objc func copyFiles(_ sender: Any?) { transfer(move: false) }
    @objc func moveFiles(_ sender: Any?) { transfer(move: true) }

    private func transfer(move: Bool) {
        let items = active.operationItems
        guard !items.isEmpty else { NSSound.beep(); return }
        if active.isRemote || other.isRemote {
            let dest = other.remote.map { $0.title + other.remotePath } ?? other.currentURL.path
            guard Dialogs.confirm(move ? "Move" : "Copy", "\(move ? "Move" : "Copy") \(describe(items)) to:\n\(dest)",
                                  ok: move ? "Move" : "Copy") else { return }
            remoteTransfer(items, from: active, to: other, move: move)
            return
        }
        let defaultTarget = other.currentURL.path == "/" ? "/" : other.currentURL.path + "/"
        let verb = move ? "Rename/move" : "Copy"
        guard let answer = Dialogs.prompt(title: move ? "Move" : "Copy",
                                          message: "\(verb) \(describe(items)) to:\n(append a mask like *.txt to copy only matching files)",
                                          defaultValue: defaultTarget + (items.count > 1 ? "*.*" : ""),
                                          okTitle: move ? "Move" : "Copy", alternateTitle: "In Background") else { return }
        let text = answer.text
        var target = text.trimmingCharacters(in: .newlines)
        var mask: FileMask?
        let last = (target as NSString).lastPathComponent
        // "*" always means a mask; "?" only when several items are copied (a single file may be named "What?.txt").
        if last.contains("*") || (last.contains("?") && items.count > 1) {
            mask = FileMask(last)
            let dir = (target as NSString).deletingLastPathComponent
            // A bare mask like "*.txt" means: the other panel's folder, filtered.
            target = dir.isEmpty ? defaultTarget : dir + "/"
        }
        let url = resolve(target, relativeTo: active.currentURL)
        let isDirTarget = target.hasSuffix("/") || url.isExistingDirectory || items.count > 1
        let destDir = isDirTarget ? url : url.deletingLastPathComponent()
        let newName = isDirTarget ? nil : url.lastPathComponent
        runTransfer(items.map(\.url), destDir: destDir, newName: newName, move: move, mask: mask, background: answer.alternate)
    }

    @objc func copyInPlace(_ sender: Any?) {
        if blockedOnRemote("Copy in the same folder") { return }
        guard let it = active.cursorItem, !it.isParent else { return }
        guard let name = Dialogs.prompt(title: "Copy", message: "Copy \"\(it.name)\" in the same folder as:",
                                        defaultValue: it.name, selectBaseName: true), !name.isEmpty, name != it.name else { return }
        let url = resolve(name, relativeTo: active.currentURL)
        runTransfer([it.url], destDir: url.deletingLastPathComponent(), newName: url.lastPathComponent, move: false, mask: nil,
                    select: url.lastPathComponent)
    }

    func performTransfer(_ urls: [URL], to dest: URL, move: Bool) {
        if !dest.isFileURL {
            // Dropped or pasted onto an FTP/SFTP panel: upload into the folder shown there.
            guard let panel = [left!, right!].first(where: { $0.isRemote && $0.currentURL == dest }) else {
                Dialogs.info("Upload", "Drop files onto the remote panel's file list (not onto a folder in it).")
                return
            }
            let items = urls.compactMap { FileItem.make($0) }
            let source = [left!, right!].first { !$0.isRemote && $0.currentURL.standardizedFileURL == urls.first?.deletingLastPathComponent().standardizedFileURL } ?? active!
            remoteTransfer(items, from: source, to: panel, move: move)
            return
        }
        runTransfer(urls, destDir: dest, newName: nil, move: move, mask: nil)
    }

    private func runTransfer(_ urls: [URL], destDir: URL, newName: String?, move: Bool, mask: FileMask?, select: String? = nil,
                             background: Bool = false) {
        let job = TransferJob(sources: urls, destDir: destDir, newName: newName, move: move, mask: mask)
        // The panel the files came from (dropped files may come from the inactive panel or from Finder).
        let parent = urls.first?.deletingLastPathComponent().standardizedFileURL
        let src = [active!, other].first { $0.currentURL.standardizedFileURL == parent } ?? active!
        job.start(on: window, background: background) { [weak self] in
            guard let self else { return }
            if !job.undoPairs.isEmpty {
                if job.isMove {
                    self.registerUndoMove(job.undoPairs.map { ($0.destination, $0.source) }, name: "Move")
                } else {
                    self.registerUndoTrash(job.undoPairs.map(\.destination), name: "Copy")
                }
            }
            src.unmark(job.completedSources.map(\.lastPathComponent))
            self.left.reload()
            self.right.reload()
            if let select { src.select(name: select) }
        }
    }

    @objc func renameFile(_ sender: Any?) {
        guard let it = active.cursorItem, !it.isParent else { return }
        guard let name = Dialogs.prompt(title: "Rename", message: "Rename \"\(it.name)\" to:", defaultValue: it.name,
                                        selectBaseName: !it.isFolder, okTitle: "Rename"),
              !name.isEmpty, name != it.name else { return }
        if active.isRemote {
            remoteRename(it, to: name)
            return
        }
        let dst = resolve(name, relativeTo: active.currentURL)
        // Same inode: a case-only rename on a case-insensitive volume, which only plain rename() allows.
        let caseOnly = pathExists(dst) && isSameFile(it.url, dst)
        if pathExists(dst) && !caseOnly {
            Dialogs.error("Cannot rename", "\"\(dst.lastPathComponent)\" already exists.")
            return
        }
        // RENAME_EXCL: a file that appeared under the new name since the check above is never replaced.
        let rc = caseOnly ? Darwin.rename(it.url.path, dst.path) : renamex_np(it.url.path, dst.path, 0x4)
        if rc != 0 {
            if errno == EXDEV {
                runTransfer([it.url], destDir: dst.deletingLastPathComponent(), newName: dst.lastPathComponent, move: true, mask: nil)
                return
            }
            Dialogs.error("Cannot rename", errno == EEXIST ? "\"\(dst.lastPathComponent)\" already exists." : String(cString: strerror(errno)))
            return
        }
        registerUndoMove([(dst, it.url)], name: "Rename")
        active.reload(selectName: dst.deletingLastPathComponent().standardizedFileURL == active.currentURL.standardizedFileURL
                      ? dst.lastPathComponent : nil)
        other.reload()
    }

    @objc func makeDirectory(_ sender: Any?) {
        let suggestion = active.cursorItem.flatMap { $0.isParent ? nil : $0.baseName } ?? ""
        guard let name = Dialogs.prompt(title: "New folder", message: "New folder (directory):\n(use a/b/c to create nested folders)",
                                        defaultValue: suggestion, okTitle: "Create"),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if active.isRemote {
            remoteMakeDirectory(name)
            return
        }
        let url = resolve(name, relativeTo: active.currentURL)
        // The outermost folder that doesn't exist yet: that is what Undo removes.
        var created = url
        while !pathExists(created.deletingLastPathComponent()) { created = created.deletingLastPathComponent() }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            registerUndoTrash([created], name: "New Folder")
        } catch {
            Dialogs.error("Cannot create folder", error.localizedDescription)
            return
        }
        let base = active.currentURL.standardizedFileURL.path
        var first: String?
        if url.path.hasPrefix(base == "/" ? "/" : base + "/") {
            let rel = String(url.path.dropFirst(base == "/" ? 1 : base.count + 1))
            first = rel.split(separator: "/").first.map(String.init)
        }
        active.reload(selectName: first)
    }

    @objc func deleteToTrash(_ sender: Any?) { deleteFiles(permanent: false) }
    @objc func deletePermanently(_ sender: Any?) { deleteFiles(permanent: true) }

    func deleteFiles(permanent requested: Bool) {
        let items = active.operationItems
        guard !items.isEmpty else { NSSound.beep(); return }
        if active.isRemote {
            remoteDelete(items)
            return
        }
        let permanent = requested || !Settings.deleteToTrash
        let msg = permanent
            ? "Do you really want to permanently delete \(describe(items))?\nThis cannot be undone."
            : "Do you really want to move \(describe(items)) to the Trash?"
        // Permanent deletion is always confirmed; moving to the Trash only when enabled in Settings.
        if permanent || Settings.confirmDelete {
            guard Dialogs.confirm(permanent ? "Delete" : "Move to Trash", msg, ok: permanent ? "Delete" : "Move to Trash",
                                  destructive: permanent) else { return }
        }
        let job = DeleteJob(urls: items.map(\.url), permanent: permanent)
        let src = active!
        job.start(on: window) { [weak self] in
            if !job.trashed.isEmpty {
                self?.registerUndoMove(job.trashed.map { ($0.inTrash, $0.original) }, name: "Move to Trash")
            }
            src.unmark(items.map(\.name))
            self?.refreshBoth()
        }
    }

    // MARK: - Archives

    @objc func packFiles(_ sender: Any?) {
        if blockedOnRemote("Packing") { return }
        let items = active.operationItems
        guard !items.isEmpty else { NSSound.beep(); return }
        let baseName = items.count == 1 ? items[0].baseName : active.currentURL.lastPathComponent
        let def = other.currentURL.appendingPathComponent((baseName.isEmpty ? "archive" : baseName) + ".zip").path
        guard let text = Dialogs.prompt(title: "Pack files",
                                        message: "Pack \(describe(items)) to archive:\n(.zip, .tar, .tar.gz/.tgz, .tar.bz2, .tar.xz)",
                                        defaultValue: def, selectBaseName: true, okTitle: "Pack") else { return }
        packFilesTo(resolve(text, relativeTo: active.currentURL))
    }

    func packFilesTo(_ archive: URL) {
        // "./name" so that names starting with "-" or "@" are never taken as options by zip/tar.
        let names = active.operationItems.map { "./" + $0.name }
        guard !names.isEmpty else { return }
        if pathExists(archive) {
            guard Dialogs.confirm("Archive exists", "\(archive.path) already exists. Replace it?", ok: "Replace",
                                  destructive: true) else { return }
            do {
                try FileManager.default.trashItem(at: archive, resultingItemURL: nil)
            } catch {
                Dialogs.error("Cannot replace archive", error.localizedDescription)
                return
            }
        }
        let lower = archive.lastPathComponent.lowercased()
        let exe: String
        var args: [String]
        if lower.hasSuffix(".zip") {
            exe = "/usr/bin/zip"
            args = ["-r", "-y", "-q", archive.path] + names
        } else {
            exe = "/usr/bin/tar"
            let flag: String
            if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { flag = "-czf" }
            else if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz") || lower.hasSuffix(".tbz2") { flag = "-cjf" }
            else if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { flag = "-cJf" }
            else { flag = "-cf" }
            args = [flag, archive.path, "--"] + names
        }
        TaskRunner.run(title: "Packing", executable: exe, arguments: args, cwd: active.currentURL, window: window,
                       environment: Self.utf8Environment) { [weak self] status, out in
            self?.refreshBoth()
            if status != 0 { Dialogs.error("Packing failed (exit \(status))", out) }
        }
    }

    @objc func unpackFiles(_ sender: Any?) {
        if blockedOnRemote("Unpacking") { return }
        let items = active.operationItems.filter(\.isArchive)
        guard !items.isEmpty else {
            Dialogs.info("Unpack", "Select one or more archives (zip, tar, gz, bz2, xz, 7z, rar, iso…) first.")
            return
        }
        guard let text = Dialogs.prompt(title: "Unpack files", message: "Unpack \(describe(items)) to:",
                                        defaultValue: other.currentURL.path + "/", okTitle: "Unpack") else { return }
        let dest = resolve(text, relativeTo: active.currentURL)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        extract(items.map(\.url), to: dest, members: [])
    }

    /// Extracts archives one after another. `members` limits extraction to the given paths.
    /// Environment for tar/zip so that non-ASCII names are handled as UTF-8 (apps launched from Finder have no locale).
    static var utf8Environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }

    /// bsdtar treats member names as patterns; escape the pattern characters so names match literally.
    static func tarLiteral(_ name: String) -> String {
        var out = ""
        for ch in name {
            if "\\*?[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Extracts archives one after another. `members` limits extraction to the given paths.
    /// Each archive is unpacked into a hidden temporary folder first and then moved into `dest`
    /// with the usual overwrite questions, so existing files are never replaced silently.
    func extract(_ archives: [URL], to dest: URL, members: [String], completion: (() -> Void)? = nil) {
        guard let first = archives.first else {
            refreshBoth()
            completion?()
            return
        }
        let rest = Array(archives.dropFirst())
        let staging = dest.appendingPathComponent(".fileadmiral-unpack-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            Dialogs.error("Cannot unpack", error.localizedDescription)
            return
        }
        let isZip = first.pathExtension.lowercased() == "zip"
        let exe: String
        let args: [String]
        if isZip && members.isEmpty {
            exe = "/usr/bin/ditto"
            args = ["-x", "-k", first.path, staging.path]
        } else {
            exe = "/usr/bin/tar"
            args = ["-xf", first.path, "-C", staging.path, "--"] + members.map(Self.tarLiteral)
        }
        let cleanup = { try? FileManager.default.removeItem(at: staging) }
        TaskRunner.run(title: "Unpacking \(first.lastPathComponent)", executable: exe, arguments: args, cwd: dest, window: window,
                       environment: Self.utf8Environment) { [weak self] status, out in
            guard let self else { cleanup(); return }
            if status != 0 {
                cleanup()
                Dialogs.error("Unpacking \(first.lastPathComponent) failed (exit \(status))", out)
                self.extract(rest, to: dest, members: members, completion: completion)
                return
            }
            let items = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
            let job = TransferJob(sources: items, destDir: dest, newName: nil, move: true)
            job.start(on: self.window) {
                cleanup()
                self.extract(rest, to: dest, members: members, completion: completion)
            }
        }
    }

    func browseArchive(_ url: URL, from panel: FilePanel) -> Bool {
        ArchiveWindowController.show(archive: url, controller: self)
        return true
    }

    // MARK: - Selection

    @objc func selectGroup(_ sender: Any?) {
        guard let mask = Dialogs.prompt(title: "Select", message: "Select files (mask, e.g. *.txt;*.md — end with / for folders):",
                                        defaultValue: UserDefaults.standard.string(forKey: "lastMask") ?? "*.*") else { return }
        UserDefaults.standard.set(mask, forKey: "lastMask")
        active.mark(mask: mask, on: true)
    }

    @objc func unselectGroup(_ sender: Any?) {
        guard let mask = Dialogs.prompt(title: "Unselect", message: "Unselect files (mask):",
                                        defaultValue: UserDefaults.standard.string(forKey: "lastMask") ?? "*.*") else { return }
        active.mark(mask: mask, on: false)
    }

    @objc func invertSelection(_ sender: Any?) { active.invertMarks() }
    @objc func selectAllFiles(_ sender: Any?) { active.markAll(true) }
    @objc func unselectAllFiles(_ sender: Any?) { active.markAll(false) }

    @objc func selectSameExtension(_ sender: Any?) {
        guard let it = active.cursorItem, !it.isParent, !it.isFolder else { return }
        active.mark(mask: it.ext.isEmpty ? "*" : "*.\(it.ext)", on: true)
    }

    @objc func compareDirectories(_ sender: Any?) {
        func files(_ p: FilePanel) -> [String: FileItem] {
            Dictionary(p.items.filter { !$0.isDirectory }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let l = files(left), r = files(right)
        var lm = Set<String>(), rm = Set<String>()
        for (n, a) in l {
            guard let b = r[n] else { lm.insert(n); continue }
            let dt = a.modified.timeIntervalSince(b.modified)
            if dt > 2 { lm.insert(n) } else if dt < -2 { rm.insert(n) } else if a.size != b.size { lm.insert(n); rm.insert(n) }
        }
        for n in r.keys where l[n] == nil { rm.insert(n) }
        left.setMarked(lm)
        right.setMarked(rm)
        if lm.isEmpty && rm.isEmpty {
            Dialogs.info("Compare directories", "The files in both directories are identical (by name, date and size).")
        }
    }

    // MARK: - Navigation commands

    @objc func goBack(_ sender: Any?) { active.goBack() }
    @objc func goForward(_ sender: Any?) { active.goForward() }
    @objc func goParent(_ sender: Any?) { active.goParent() }
    @objc func goHome(_ sender: Any?) { active.navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
    @objc func goRoot(_ sender: Any?) { active.navigate(to: URL(fileURLWithPath: "/")) }
    @objc func openCursorItem(_ sender: Any?) { active.openCursor() }

    @objc func goToFolder(_ sender: Any?) {
        guard let text = Dialogs.prompt(title: "Go to folder", message: "Folder path:", defaultValue: active.currentURL.path,
                                        okTitle: "Go") else { return }
        if let fs = active.remote {
            let path = text.hasPrefix("/") ? text : RemotePath.join(active.remotePath, text)
            active.navigateRemote(fs, path: path, select: nil, recordHistory: true)
            return
        }
        let url = resolve(text, relativeTo: active.currentURL)
        if url.isExistingDirectory {
            active.navigate(to: url)
        } else if pathExists(url) {
            goToFile(url)
        } else {
            NSSound.beep()
        }
    }

    func openCursorIn(side: PanelSide) {
        let target = side == .left ? left! : right!
        guard let it = active.cursorItem else { return }
        if let fs = active.remote {
            let path = it.isDirectory ? it.url.path : active.remotePath
            target.openRemote(fs, path: path, inNewTab: false)
            return
        }
        let url = it.isFolder ? (it.isParent ? active.currentURL.deletingLastPathComponent() : it.url) : active.currentURL
        target.navigate(to: url)
    }

    @objc func swapPanels(_ sender: Any?) {
        let (lt, la) = left.exportTabs()
        let (rt, ra) = right.exportTabs()
        left.importTabs(rt, active: ra)
        right.importTabs(lt, active: la)
        other.activate()
    }

    @objc func targetEqualsSource(_ sender: Any?) {
        if let fs = active.remote {
            other.openRemote(fs, path: active.remotePath, inNewTab: false)
            return
        }
        other.navigate(to: active.currentURL)
    }

    @objc func newTab(_ sender: Any?) { active.newTab() }

    @objc func newTabFromCursor(_ sender: Any?) {
        if let it = active.cursorItem, it.isFolder, !it.isParent { active.newTab(url: it.url) } else { active.newTab() }
    }

    @objc func closeTab(_ sender: Any?) { active.closeTab() }
    @objc func nextTab(_ sender: Any?) { active.nextTab() }
    @objc func prevTab(_ sender: Any?) { active.prevTab() }

    @objc func toggleHidden(_ sender: Any?) {
        showHidden.toggle()
        UserDefaults.standard.set(showHidden, forKey: "showHidden")
        updateHiddenButton()
        refreshBoth()
    }

    @objc func sortByName(_ sender: Any?) { active.setSort(.name, ascending: true) }
    @objc func sortByExt(_ sender: Any?) { active.setSort(.ext, ascending: true) }
    @objc func sortBySize(_ sender: Any?) { active.setSort(.size, ascending: false) }
    @objc func sortByDate(_ sender: Any?) { active.setSort(.date, ascending: false) }
    @objc func reverseSort(_ sender: Any?) { active.setSort(active.sortKey, ascending: !active.ascending) }

    @objc func calculateAllSizes(_ sender: Any?) { active.calculateAllSizes() }

    func goToFile(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        active.navigate(to: dir, select: url.lastPathComponent)
        window?.makeKeyAndOrderFront(nil)
        active.activate()
    }

    func showAndMark(dir: URL, names: Set<String>) {
        if active.currentURL.standardizedFileURL != dir { active.navigate(to: dir) }
        active.setMarked(names)
        window?.makeKeyAndOrderFront(nil)
        active.activate()
    }

    // MARK: - Hotlist & history

    @objc func showHotlist(_ sender: Any?) {
        let menu = NSMenu()
        for (i, p) in hotlist.enumerated() {
            let mi = NSMenuItem(title: (p as NSString).abbreviatingWithTildeInPath, action: #selector(hotlistChosen(_:)),
                                keyEquivalent: i < 9 ? "\(i + 1)" : "")
            mi.keyEquivalentModifierMask = []
            mi.target = self
            mi.representedObject = p
            mi.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add current directory", action: #selector(addToHotlist(_:)), keyEquivalent: "a")
        add.keyEquivalentModifierMask = []
        add.target = self
        menu.addItem(add)
        let removeMenu = NSMenu()
        for p in hotlist {
            let mi = NSMenuItem(title: (p as NSString).abbreviatingWithTildeInPath, action: #selector(removeFromHotlist(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = p
            removeMenu.addItem(mi)
        }
        let remove = NSMenuItem(title: "Remove", action: nil, keyEquivalent: "")
        remove.submenu = removeMenu
        menu.addItem(remove)
        let header = active.pathHeader
        menu.popUp(positioning: nil, at: NSPoint(x: 8, y: header.bounds.height), in: header)
    }

    @objc private func hotlistChosen(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        active.navigate(to: URL(fileURLWithPath: p))
    }

    @objc func addToHotlist(_ sender: Any?) {
        if blockedOnRemote("Adding to the hotlist") { return }
        var h = hotlist
        let p = active.currentURL.path
        if !h.contains(p) { h.append(p) }
        hotlist = h
    }

    @objc private func removeFromHotlist(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        hotlist = hotlist.filter { $0 != p }
    }

    func showHistory(for panel: FilePanel) {
        let menu = NSMenu()
        var seen = Set<String>()
        for u in panel.history.reversed() where !seen.contains(u.path) {
            seen.insert(u.path)
            let mi = NSMenuItem(title: u.abbreviatedPath, action: #selector(historyChosen(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = u
            menu.addItem(mi)
            if seen.count >= 25 { break }
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "(no history)", action: nil, keyEquivalent: ""))
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 8, y: panel.pathHeader.bounds.height), in: panel.pathHeader)
    }

    @objc func showHistoryMenu(_ sender: Any?) { showHistory(for: active) }

    @objc private func historyChosen(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        active.navigate(to: u)
    }

    // MARK: - Tools

    @objc func searchFiles(_ sender: Any?) {
        if blockedOnRemote("Find Files") { return }
        SearchWindowController.show(controller: self, startDir: active.currentURL)
    }

    @objc func multiRename(_ sender: Any?) {
        if blockedOnRemote("Multi-Rename") { return }
        var items = active.operationItems
        if items.isEmpty { items = active.items.filter { !$0.isParent } }
        guard !items.isEmpty else { NSSound.beep(); return }
        let panel = active!
        MultiRenameWindowController.show(urls: items.map(\.url)) { [weak self] in
            panel.markAll(false)
            self?.refreshBoth()
        }
    }

    @objc func quickLook(_ sender: Any?) {
        if blockedOnRemote("Quick Look") { return }
        guard let ql = QLPreviewPanel.shared() else { return }
        if ql.isVisible {
            ql.orderOut(nil)
        } else {
            active.activate()
            ql.makeKeyAndOrderFront(nil)
        }
    }

    @objc func copyNames(_ sender: Any?) {
        let s = active.operationItems.map(\.name).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc func copyFullNames(_ sender: Any?) {
        let prefix = active.remote?.title ?? ""
        let s = active.operationItems.map { prefix + $0.url.path }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc func revealInFinder(_ sender: Any?) {
        if blockedOnRemote("Show in Finder") { return }
        let urls = active.operationItems.map(\.url)
        if urls.isEmpty {
            NSWorkspace.shared.open(active.currentURL)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    @objc func getInfo(_ sender: Any?) {
        if blockedOnRemote("Get Info") { return }
        for it in active.operationItems.prefix(10) {
            let escaped = it.url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let src = """
            tell application "Finder"
                activate
                open information window of (POSIX file "\(escaped)" as alias)
            end tell
            """
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            if let err { Dialogs.error("Get Info failed", "\(err[NSAppleScript.errorMessage] ?? err)") ; break }
        }
    }

    @objc func openTerminal(_ sender: Any?) {
        if blockedOnRemote("Open Terminal") { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", Settings.terminalApp.rawValue, active.currentURL.path]
        try? p.run()
    }

    @objc func focusCommandLine(_ sender: Any?) {
        window?.makeFirstResponder(commandField)
    }

    // MARK: - Plugins

    /// Rebuilds the Plugins menu and the plugin toolbar buttons from the plugins folder.
    func reloadPlugins() {
        let pm = PluginManager.shared
        pm.reload()
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Plugins" })?.submenu else { return }
        menu.removeAllItems()
        for p in pm.commandPlugins {
            let mi = NSMenuItem(title: p.name, action: #selector(runPlugin(_:)), keyEquivalent: p.shortcut?.key ?? "")
            mi.keyEquivalentModifierMask = p.shortcut?.modifiers ?? []
            mi.target = nil // responder chain: only while the main window is in front
            mi.representedObject = p.id
            mi.toolTip = p.description
            mi.image = NSImage(systemSymbolName: p.icon, accessibilityDescription: nil)
            menu.addItem(mi)
        }
        let viewers = pm.plugins.filter { $0.kind == .viewer }
        if !viewers.isEmpty {
            if !pm.commandPlugins.isEmpty { menu.addItem(.separator()) }
            let header = NSMenuItem(title: "Lister (F3) plugins:", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for p in viewers {
                let mi = NSMenuItem(title: "   " + p.name, action: nil, keyEquivalent: "")
                mi.isEnabled = false
                mi.toolTip = p.description
                menu.addItem(mi)
            }
        }
        if pm.plugins.isEmpty {
            let none = NSMenuItem(title: "No plugins installed", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        for (title, sel) in [("Open Plugins Folder", #selector(openPluginsFolder(_:))),
                             ("Reload Plugins", #selector(reloadPluginsAction(_:))),
                             ("Install Sample Plugins", #selector(installSamplePlugins(_:))),
                             ("How to Write a Plugin…", #selector(showPluginHelp(_:)))] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        populateToolbar()
        if !pm.errors.isEmpty {
            Dialogs.error("Some plugins could not be loaded", pm.errors.joined(separator: "\n"))
        }
    }

    @objc func runPlugin(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String ?? (sender as? NSButton)?.identifier?.rawValue,
              let plugin = PluginManager.shared.plugins.first(where: { $0.id == id }) else { return }
        if blockedOnRemote("Plugin \"\(plugin.name)\"") { return }
        PluginManager.shared.run(plugin, controller: self)
    }

    @objc func openPluginsFolder(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: PluginManager.shared.folder, withIntermediateDirectories: true)
        if active.currentURL.standardizedFileURL != PluginManager.shared.folder.standardizedFileURL {
            active.newTab(url: PluginManager.shared.folder)
        }
    }

    @objc func reloadPluginsAction(_ sender: Any?) { reloadPlugins() }

    @objc func installSamplePlugins(_ sender: Any?) {
        let installed = PluginManager.shared.installSamples()
        reloadPlugins()
        Dialogs.info("Sample plugins",
                     installed.isEmpty ? "The sample plugins are already installed."
                                       : "Installed: " + installed.joined(separator: ", ")
                                         + ".\n\nThey are in the Plugins menu; viewer plugins appear as extra tabs in the Lister (F3).")
    }

    @objc func showPluginHelp(_ sender: Any?) {
        ViewerWindowController.show(text: Help.plugins, title: "FileAdmiral — Writing plugins")
    }

    @objc func chooseColorScheme(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Theme.schemeName = name
    }

    @objc func biggerFont(_ sender: Any?) { Theme.fontSize += 1 }
    @objc func smallerFont(_ sender: Any?) { Theme.fontSize -= 1 }
    @objc func defaultFontSize(_ sender: Any?) { Theme.resetFontSize() }

    @objc private func themeDidChange(_ n: Notification) {
        populateToolbar() // icons are colored per theme
        applyChromeTheme()
    }

    /// Colors the window chrome (background, toolbar labels, command line, F-key bar) for the theme.
    func applyChromeTheme() {
        let retro = Theme.current.retro
        if let content = window?.contentView {
            content.wantsLayer = true
            content.layer?.backgroundColor = retro?.windowBackground.cgColor
        }
        window?.contentView?.subviews.forEach { $0.needsDisplay = true }
        promptLabel.font = Theme.font
        commandField.font = Theme.font
        promptLabel.textColor = retro?.commandText ?? .labelColor
        commandField.drawsBackground = true
        commandField.backgroundColor = retro?.commandBackground ?? .textBackgroundColor
        commandField.textColor = retro?.commandText ?? .textColor
        commandField.isBezeled = retro == nil
        functionKeyButtons.forEach { $0.applyTheme() }
        for case let b as ToolbarButton in toolbarStack.arrangedSubviews {
            b.contentTintColor = retro?.barText
            if let r = retro, !b.title.isEmpty {
                b.attributedTitle = NSAttributedString(string: b.title, attributes: [.font: NSFont.systemFont(ofSize: 10),
                                                                                    .foregroundColor: r.barText])
            } else if !b.title.isEmpty {
                b.attributedTitle = NSAttributedString(string: b.title, attributes: [.font: NSFont.systemFont(ofSize: 10),
                                                                                    .foregroundColor: NSColor.labelColor])
            }
        }
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.show(controller: self)
    }

    /// Shows or hides the toolbar, command line and function key bar as set in Settings.
    @objc private func applyLayoutSettings(_ n: Notification?) {
        toolbarView.isHidden = !Settings.showToolbar
        toolbarHeight.constant = Settings.showToolbar ? (showToolbarLabels ? 56 : 36) : 0
        commandRow.isHidden = !Settings.showCommandLine
        commandRowHeight.constant = Settings.showCommandLine ? 22 : 0
        functionKeyBar.isHidden = !Settings.showFunctionKeys
        functionKeyBarHeight.constant = Settings.showFunctionKeys ? 24 : 0
        updateToolbarInset()
    }

    @objc func showPermissions(_ sender: Any?) {
        PermissionsWindowController.show()
    }

    @objc func showKeyboardHelp(_ sender: Any?) {
        ViewerWindowController.show(text: Help.keyboard, title: "FileAdmiral — Keyboard shortcuts")
    }
}
