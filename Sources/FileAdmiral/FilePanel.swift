import AppKit
import Quartz
import UniformTypeIdentifiers

enum PanelSide: String {
    case left, right
}

enum SortKey: String {
    case name, ext, size, date, attr
}

struct TabState {
    var url: URL
    var back: [URL] = []
    var forward: [URL] = []
    var cursorName: String?
    var markedNames: Set<String> = []
    /// Set while the tab shows an FTP/SFTP connection; `url` then is a remote URL (not file:).
    var remote: RemoteFileSystem?
}

/// Clickable path header above the file list.
final class PathHeader: NSTextField {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// Clicking a folder name in the path navigates there (like Finder's path bar).
    var onSegment: ((URL) -> Void)?

    private var text = ""
    private var segments: [(range: NSRange, url: URL)] = []
    private var hovered: Int? { didSet { if hovered != oldValue { render() } } }

    /// Sets the text and the clickable folder ranges in it.
    func configure(text: String, segments: [(range: NSRange, url: URL)]) {
        self.text = text
        self.segments = segments
        hovered = nil
        render()
    }

    private var attributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingHead
        return [.font: font ?? Theme.font, .foregroundColor: textColor ?? .labelColor, .paragraphStyle: style]
    }

    private func render() {
        let s = NSMutableAttributedString(string: text, attributes: attributes)
        if let h = hovered, h < segments.count {
            s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: segments[h].range)
        }
        attributedStringValue = s
    }

    override var font: NSFont? { didSet { if !text.isEmpty { render() } } }
    override var textColor: NSColor? { didSet { if !text.isEmpty { render() } } }

    /// Horizontal center of segment `i` (for tests).
    func centerX(ofSegment i: Int) -> CGFloat? {
        stride(from: 0, to: bounds.width, by: 1).first { segment(atX: $0) == i }.map { $0 + 3 }
    }

    /// Index of the segment under `x`, taking head truncation ("…/long/path") into account.
    func segment(atX x: CGFloat) -> Int? {
        let ns = text as NSString
        let attrs = attributes
        let width = { (r: NSRange) in NSAttributedString(string: ns.substring(with: r), attributes: attrs).size().width }
        let inset: CGFloat = 2
        let available = bounds.width - 2 * inset
        let full = width(NSRange(location: 0, length: ns.length))
        for (i, seg) in segments.enumerated() {
            let start: CGFloat, end: CGFloat
            if full <= available {
                start = inset + width(NSRange(location: 0, length: seg.range.location))
            } else {
                // Truncated at the head: the end of the text is aligned with the right edge.
                start = inset + available - width(NSRange(location: seg.range.location, length: ns.length - seg.range.location))
            }
            end = start + width(seg.range)
            if x >= start && x <= end && start >= inset { return i }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = segment(atX: convert(event.locationInWindow, from: nil).x)
        (hovered == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        if let i = segment(atX: convert(event.locationInWindow, from: nil).x), i < segments.count - 1 {
            onSegment?(segments[i].url)
        } else {
            onClick?()
        }
    }
}

/// Cell that switches its text colour depending on mark / cursor state.
final class FileCellView: NSTableCellView {
    var isMarked = false { didSet { updateColor() } }
    var isDim = false { didSet { updateColor() } }
    var isFolder = false { didSet { updateColor() } }
    /// Finder tag dots after the name (name column only).
    var tagDots: TagDotsView?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    func updateColor() {
        let t = Theme.current
        let onCursor = backgroundStyle == .emphasized
        if isMarked {
            textField?.textColor = onCursor ? t.markedOnCursor : t.marked
        } else if onCursor {
            textField?.textColor = t.cursorText
        } else {
            textField?.textColor = isDim ? t.hiddenText : (isFolder ? t.folderText : t.text)
        }
    }
}

/// Row view that draws the cursor bar in the theme's colors.
final class FileRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let t = Theme.current
        (isEmphasized ? t.cursor : t.cursorInactive).setFill()
        bounds.fill()
    }
}

/// Table view that routes keyboard and mouse handling to its panel.
final class FileTableView: NSTableView, QLPreviewPanelDataSource {
    weak var panel: FilePanel?

    override func keyDown(with event: NSEvent) {
        if panel?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.shift) { panel?.endShiftGesture() }
        super.flagsChanged(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if row >= 0, let panel {
            if mods.contains(.command) {
                panel.toggleMark(row: row)
                selectRowIndexes([row], byExtendingSelection: false)
                return
            }
            if mods.contains(.shift) {
                panel.markRange(from: selectedRow, to: row)
                selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
        // Empty space below the list: no file menu, it would act on a file the user didn't click.
        guard row >= 0 else { return nil }
        selectRowIndexes([row], byExtendingSelection: false)
        return panel?.contextMenu()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { panel?.didBecomeActive() }
        return ok
    }

    override func selectAll(_ sender: Any?) {
        panel?.markAll(true)
    }

    @objc func copy(_ sender: Any?) {
        panel?.copyToPasteboard()
    }

    @objc func paste(_ sender: Any?) {
        panel?.pasteFromPasteboard()
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        // Only "Find…" opens Find Files; Find Next etc. mean nothing in a file list.
        if let item = sender as? NSMenuItem, item.tag != Int(NSFindPanelAction.showFindPanel.rawValue) { return }
        panel?.controller?.searchFiles(sender)
    }

    // MARK: Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        self.panel?.previewURLs.count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let urls = self.panel?.previewURLs, index < urls.count else { return nil }
        return urls[index] as NSURL
    }
}

final class FilePanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSCollectionViewDataSource,
    NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    weak var controller: MainWindowController?
    let side: PanelSide

    private(set) var tabs: [TabState] = []
    private(set) var activeTab = 0
    var currentURL: URL { tabs[activeTab].url }

    /// The FTP/SFTP connection of the visible tab, if any.
    var remote: RemoteFileSystem? { activeTab >= 0 && activeTab < tabs.count ? tabs[activeTab].remote : nil }
    var isRemote: Bool { remote != nil }
    /// Remote folder path of the visible tab.
    var remotePath: String { currentURL.path.isEmpty ? "/" : currentURL.path }
    /// A listing (local or remote) is on its way; the header says "(loading…)".
    private var loading = false
    /// Bumped by every reload; a listing that arrives for an older generation is dropped.
    private var listingGeneration = 0
    /// How long `reload` waits for a local listing before showing the loading state and finishing
    /// asynchronously. Small local folders list well within this and behave like a synchronous call.
    /// (The self-test sets it to 0 to exercise the asynchronous path.)
    static var synchronousListingTimeout: TimeInterval = 0.15

    /// Hand-off between the listing thread and the main thread (see `reload`).
    private final class ListingBox {
        let lock = NSLock()
        var result: [FileItem]?
        var onReady: (([FileItem]) -> Void)?
    }

    private(set) var items: [FileItem] = []
    private(set) var marked = Set<String>()
    private var dirSizes: [String: Int64] = [:]
    private var loadedURL: URL?
    private(set) var sortKey: SortKey = .name
    private(set) var ascending = true

    var isActive = false {
        didSet {
            updateHeader()
            if tabBarHeight != nil { updateTabBar() }
        }
    }

    let tableView = FileTableView()

    enum ViewMode: String { case details, thumbnails, tree }
    /// Details (list) or Thumbnails. In thumbnail mode the table is hidden but still holds the cursor.
    private(set) var viewMode: ViewMode = .details
    let grid = ThumbnailGridView()
    let tree = FolderTreeView(frame: .zero)
    private let treeScroll = NSScrollView()
    /// The list/thumbnail mode to return to when leaving the folder tree.
    private var modeBeforeTree: ViewMode = .details
    private let viewSwitch = NSSegmentedControl()

    /// Icon for the ".." entry: a folder with a small "up" badge.
    static let parentFolderIcon: NSImage = {
        let folder = NSWorkspace.shared.icon(for: .folder)
        let badgeConfig = NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemBlue]))
        let badge = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(badgeConfig)
        return NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            folder.draw(in: rect)
            if let badge {
                let side = rect.width * 0.5
                badge.draw(in: NSRect(x: rect.maxX - side - rect.width * 0.02, y: rect.minY + rect.height * 0.08,
                                      width: side, height: side))
            }
            return true
        }
    }()
    private let gridScroll = NSScrollView()
    /// Quick View: this panel previews the file under the cursor of the other panel (TC Ctrl+Q).
    private(set) var isQuickView = false
    private let quickViewContainer = NSView()
    private var quickPreview: QLPreviewView?
    private let quickMessage = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let volumePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let freeLabel = NSTextField(labelWithString: "")
    private let tabBar = TabStrip()
    private var tabBarHeight: NSLayoutConstraint!
    private var pathHeaderHeight: NSLayoutConstraint!
    let pathHeader = PathHeader(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let quickSearchLabel = NSTextField(labelWithString: "")
    private(set) var quickSearch = ""

    private var watcher: DispatchSourceFileSystemObject?
    private var refreshPending = false
    private var iconCache: [String: NSImage] = [:]
    private var sizeJobs: [String: CancelFlag] = [:]

    private func key(_ k: String) -> String { "\(side.rawValue)\(k)" }

    init(side: PanelSide, controller: MainWindowController) {
        self.side = side
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 500))

        let d = UserDefaults.standard
        var urls = (Settings.restoreTabs ? d.stringArray(forKey: key("Tabs")) ?? [] : [])
            .map { URL(fileURLWithPath: $0) }
            .filter { $0.isExistingDirectory }
        if urls.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser
            urls = [side == .left ? home : home.appendingPathComponent("Downloads")]
            if !urls[0].isExistingDirectory { urls = [home] }
        }
        tabs = urls.map { TabState(url: $0) }
        activeTab = Settings.restoreTabs ? min(max(d.integer(forKey: key("ActiveTab")), 0), tabs.count - 1) : 0
        sortKey = SortKey(rawValue: d.string(forKey: key("Sort")) ?? "") ?? .name
        ascending = d.object(forKey: key("Asc")) as? Bool ?? true

        buildUI()
        tableView.sortDescriptors = [NSSortDescriptor(key: sortKey.rawValue, ascending: ascending)]
        rebuildVolumes()
        reload(keepCursor: false)
        updateTabBar()

        let wsnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            wsnc.addObserver(self, selector: #selector(volumesChanged(_:)), name: name, object: nil)
        }
        if let mode = ViewMode(rawValue: d.string(forKey: key("ViewMode")) ?? ""), mode != .details { setViewMode(mode) }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)), name: .themeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)), name: .settingsChanged, object: nil)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        watcher?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func saveState() {
        let d = UserDefaults.standard
        // Remote tabs are not restored (they need a live connection).
        let local = tabs.filter { $0.remote == nil }
        d.set(local.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser.path] : local.map { $0.url.path }, forKey: key("Tabs"))
        d.set(local.firstIndex { $0.url == currentURL } ?? 0, forKey: key("ActiveTab"))
        d.set(sortKey.rawValue, forKey: key("Sort"))
        d.set(ascending, forKey: key("Asc"))
    }

    // MARK: - UI

    private func smallButton(_ title: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .smallSquare
        b.controlSize = .small
        b.font = Theme.smallFont
        b.toolTip = tip
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        return b
    }

    private func buildUI() {
        volumePopup.controlSize = .small
        volumePopup.font = Theme.smallFont
        volumePopup.target = self
        volumePopup.action = #selector(volumeChosen(_:))
        volumePopup.toolTip = "Change volume"
        volumePopup.setContentHuggingPriority(.required, for: .horizontal)

        freeLabel.font = Theme.smallFont
        freeLabel.textColor = .secondaryLabelColor
        freeLabel.lineBreakMode = .byTruncatingTail
        freeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        freeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let homeBtn = smallButton("~", "Home directory (⌘⇧H)", #selector(goHomeAction(_:)))
        let rootBtn = smallButton("/", "Root directory (⌘\\)", #selector(goRootAction(_:)))
        let upBtn = smallButton("..", "Parent directory (⌫)", #selector(goParentAction(_:)))

        viewSwitch.segmentCount = 3
        viewSwitch.trackingMode = .selectOne
        viewSwitch.segmentStyle = .rounded
        viewSwitch.controlSize = .small
        for (i, (symbol, tip)) in [("list.bullet", "List view (⌃F2)"), ("square.grid.2x2", "Thumbnails view (⌃⇧F1)"),
                                   ("list.bullet.indent", "Folder tree (⌃F8)")].enumerated() {
            viewSwitch.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: tip), forSegment: i)
            viewSwitch.setToolTip(tip, forSegment: i)
            viewSwitch.setWidth(26, forSegment: i)
        }
        viewSwitch.selectedSegment = 0
        viewSwitch.target = self
        viewSwitch.action = #selector(viewSwitchChanged(_:))
        viewSwitch.refusesFirstResponder = true
        let driveBar = NSStackView(views: [volumePopup, freeLabel, viewSwitch, homeBtn, rootBtn, upBtn])
        driveBar.orientation = .horizontal
        driveBar.spacing = 3

        tabBar.onSelect = { [weak self] i in self?.switchTab(i); self?.activate() }
        tabBar.onClose = { [weak self] i in self?.closeTab(at: i) }
        tabBar.onNew = { [weak self] in self?.newTab(); self?.activate() }
        tabBar.onOpenInNewTab = { [weak self] url in self?.newTab(url: url); self?.activate() }
        tabBar.menuForTab = { [weak self] i in self?.tabMenu(for: i) }

        pathHeader.isBezeled = false
        pathHeader.drawsBackground = true
        pathHeader.font = Theme.font
        pathHeader.lineBreakMode = .byTruncatingHead
        pathHeader.cell?.usesSingleLineMode = true
        pathHeader.onClick = { [weak self] in self?.activate() }
        pathHeader.onSegment = { [weak self] url in
            guard let self else { return }
            self.activate()
            // Going up: keep the cursor on the folder we came from.
            let current = self.currentURL.path
            let next = current.dropFirst(url.path == "/" ? 1 : url.path.count + 1).split(separator: "/").first.map(String.init)
            self.navigate(to: url, select: next)
        }
        pathHeader.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.activate()
            self.controller?.showHistory(for: self)
        }

        tableView.panel = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = Theme.rowHeight
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.allowsTypeSelect = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.style = .plain
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        let columns: [(String, String, CGFloat, NSTextAlignment)] = [
            ("name", "Name", 220, .left),
            ("ext", "Ext", 46, .left),
            ("size", "Size", 86, .right),
            ("date", "Date", 112, .left),
            ("attr", "Attr", 76, .left),
        ]
        for (id, title, width, align) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = 30
            col.headerCell.alignment = align
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            col.headerCell = ThemedHeaderCell(textCell: title)
            col.headerCell.alignment = align
            tableView.addTableColumn(col)
        }
        tableView.autosaveName = "FilePanel-\(side.rawValue)"
        tableView.autosaveTableColumns = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = false

        statusLabel.font = Theme.smallFont
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        quickSearchLabel.isBezeled = true
        quickSearchLabel.bezelStyle = .squareBezel
        quickSearchLabel.drawsBackground = true
        quickSearchLabel.backgroundColor = Theme.quickSearchBackground
        quickSearchLabel.font = Theme.font
        quickSearchLabel.isHidden = true

        buildGrid()
        quickViewContainer.isHidden = true
        quickViewContainer.wantsLayer = true
        quickMessage.alignment = .center
        quickMessage.textColor = .secondaryLabelColor
        quickMessage.translatesAutoresizingMaskIntoConstraints = false
        quickViewContainer.addSubview(quickMessage)
        NSLayoutConstraint.activate([
            quickMessage.centerXAnchor.constraint(equalTo: quickViewContainer.centerXAnchor),
            quickMessage.centerYAnchor.constraint(equalTo: quickViewContainer.centerYAnchor),
            quickMessage.widthAnchor.constraint(lessThanOrEqualTo: quickViewContainer.widthAnchor, constant: -40),
        ])
        tree.panel = self
        treeScroll.documentView = tree
        treeScroll.hasVerticalScroller = true
        treeScroll.borderType = .bezelBorder
        treeScroll.isHidden = true
        for v in [driveBar, tabBar, pathHeader, scrollView, gridScroll, treeScroll, quickViewContainer, statusLabel,
                  quickSearchLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 22)
        pathHeaderHeight = pathHeader.heightAnchor.constraint(equalToConstant: 18)
        NSLayoutConstraint.activate([
            driveBar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            driveBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            driveBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            driveBar.heightAnchor.constraint(equalToConstant: 22),

            tabBar.topAnchor.constraint(equalTo: driveBar.bottomAnchor, constant: 2),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            tabBarHeight,

            pathHeader.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 2),
            pathHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            pathHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            pathHeaderHeight,

            scrollView.topAnchor.constraint(equalTo: pathHeader.bottomAnchor, constant: 1),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            gridScroll.topAnchor.constraint(equalTo: scrollView.topAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            treeScroll.topAnchor.constraint(equalTo: scrollView.topAnchor),
            treeScroll.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            treeScroll.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            treeScroll.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            quickViewContainer.topAnchor.constraint(equalTo: scrollView.topAnchor),
            quickViewContainer.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            quickViewContainer.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            quickViewContainer.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),

            quickSearchLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 4),
            quickSearchLabel.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -4),
            quickSearchLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        // Only the user resizes panels: text that doesn't fit is truncated instead of widening the panel.
        for v in [pathHeader, freeLabel, statusLabel, volumePopup, quickSearchLabel] as [NSView] {
            v.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        }
        for stack in [driveBar] {
            stack.setClippingResistancePriority(.fittingSizeCompression, for: .horizontal)
        }
        let popupMin = volumePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 70)
        popupMin.priority = .defaultHigh
        popupMin.isActive = true
        updateHeader()
    }

    private func updateHeader() {
        if isQuickView { return }
        let p = currentURL.path
        let prefix = " " + (remote?.title ?? "")
        let text = prefix + (p == "/" ? "/" : p + "/") + (loading ? "   (loading…)" : "*.*")
        // Clickable segments: the root "/" and every folder name of the path.
        var segments: [(range: NSRange, url: URL)] = []
        let base = (prefix as NSString).length
        segments.append((NSRange(location: base, length: 1), remote?.url(for: "/") ?? URL(fileURLWithPath: "/")))
        var location = base + 1
        var path = ""
        for comp in p.split(separator: "/").map(String.init) {
            path += "/" + comp
            let length = (comp as NSString).length
            segments.append((NSRange(location: location, length: length),
                             remote?.url(for: path) ?? URL(fileURLWithPath: path, isDirectory: true)))
            location += length + 1
        }
        pathHeader.backgroundColor = isActive ? Theme.activeHeader : Theme.inactiveHeader
        pathHeader.textColor = isActive ? Theme.current.activeHeaderText : Theme.current.inactiveHeaderText
        pathHeader.font = isActive ? Theme.boldFont : Theme.font
        pathHeader.configure(text: text, segments: segments)
    }

    /// Shows a message in the status line for a few seconds.
    func showTransientStatus(_ text: String) {
        statusLabel.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.updateStatus() }
    }

    private func updateStatus() {
        var files = 0, dirs = 0, mFiles = 0, mDirs = 0
        var total: Int64 = 0, mTotal: Int64 = 0
        for it in items where !it.isParent {
            let m = marked.contains(it.name)
            if it.isFolder {
                dirs += 1
                total += it.dirSize ?? 0
                if m { mDirs += 1; mTotal += it.dirSize ?? 0 }
            } else {
                files += 1
                total += it.effectiveSize
                if m { mFiles += 1; mTotal += it.effectiveSize }
            }
        }
        statusLabel.stringValue = "\(Fmt.kb(mTotal)) k / \(Fmt.kb(total)) k in \(mFiles) / \(files) file(s), \(mDirs) / \(dirs) dir(s)"
    }

    private func updateVolumeInfo() {
        if let fs = remote {
            freeLabel.stringValue = "[\(fs.scheme)]  \(fs.authority)"
            freeLabel.toolTip = "Connected to \(fs.title). Choose a volume on the left to disconnect."
            return
        }
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeURLKey]
        guard let rv = try? currentURL.resourceValues(forKeys: keys) else {
            freeLabel.stringValue = ""
            return
        }
        let name = (rv.volumeName ?? "?").lowercased()
        let free = rv.volumeAvailableCapacityForImportantUsage ?? Int64(rv.volumeAvailableCapacity ?? 0)
        let total = Int64(rv.volumeTotalCapacity ?? 0)
        freeLabel.stringValue = "[\(name)]  \(Fmt.kb(free)) k of \(Fmt.kb(total)) k free"
        freeLabel.toolTip = "\(Fmt.bytes(free)) free of \(Fmt.bytes(total))"
        if let vol = rv.volume {
            for item in volumePopup.itemArray {
                if let u = item.representedObject as? URL, u.standardizedFileURL == vol.standardizedFileURL {
                    volumePopup.select(item)
                    break
                }
            }
        }
    }

    func rebuildVolumes() {
        volumePopup.removeAllItems()
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        for v in vols {
            let name = (try? v.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? v.lastPathComponent
            let item = NSMenuItem(title: "[\(name)]", action: nil, keyEquivalent: "")
            item.representedObject = v
            let icon = NSWorkspace.shared.icon(forFile: v.path)
            icon.size = NSSize(width: 14, height: 14)
            item.image = icon
            volumePopup.menu?.addItem(item)
        }
        volumePopup.menu?.addItem(.separator())
        let home = NSMenuItem(title: "~ Home", action: nil, keyEquivalent: "")
        home.representedObject = FileManager.default.homeDirectoryForCurrentUser
        home.image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)
        volumePopup.menu?.addItem(home)
        updateVolumeInfo()
    }

    @objc private func themeChanged(_ n: Notification) {
        applyTheme()
    }

    @objc private func settingsChanged(_ n: Notification) {
        updateThumbnailSize()
        let name = cursorItem?.name
        items = sortItems(items)
        reloadAllViews()
        if let name { select(name: name) }
        updateStatus()
    }

    /// Re-applies colors and fonts after a theme or font size change.
    func applyTheme() {
        tableView.backgroundColor = Theme.current.panelBackground
        tree.backgroundColor = Theme.current.panelBackground
        tree.rowHeight = Theme.rowHeight
        let retro = Theme.current.retro
        wantsLayer = true
        layer?.backgroundColor = retro == nil ? nil : Theme.current.panelBackground.cgColor
        statusLabel.textColor = retro?.statusText ?? .labelColor
        // Dark panel chrome needs light control glyphs (view switch, tab "+").
        let darkChrome = retro != nil || Theme.current.isDark
        viewSwitch.appearance = NSAppearance(named: darkChrome ? .darkAqua : .aqua)
        tabBar.plusTint = retro?.statusText
        freeLabel.textColor = retro?.statusText ?? .secondaryLabelColor
        tableView.headerView?.needsDisplay = true
        grid.backgroundColors = [Theme.current.panelBackground]
        tableView.rowHeight = Theme.rowHeight
        pathHeaderHeight.constant = max(18, Theme.fontSize + 6)
        quickSearchLabel.backgroundColor = Theme.quickSearchBackground
        quickSearchLabel.textColor = Theme.current.text
        let row = tableView.selectedRow
        reloadAllViews()
        if row >= 0 { setCursor(row) }
        updateHeader()
        updateTabBar()
    }

    @objc private func volumesChanged(_ n: Notification) {
        rebuildVolumes()
        if !currentURL.isExistingDirectory {
            navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    @objc private func volumeChosen(_ sender: NSPopUpButton) {
        guard let u = sender.selectedItem?.representedObject as? URL else { return }
        navigate(to: u)
        activate()
    }

    private func updateTabBar() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let titles = tabs.map { t -> (String, String) in
            if let fs = t.remote {
                let last = t.url.path == "/" || t.url.path.isEmpty ? "/" : t.url.lastPathComponent
                return ("\(fs.scheme): \(last)", fs.title + t.url.path)
            }
            let u = t.url.standardizedFileURL
            let name = u.path == "/" ? "/" : (u == home ? "~ " + u.lastPathComponent : u.lastPathComponent)
            return (name, u.path)
        }
        tabBar.update(titles: titles, active: activeTab, panelActive: isActive)
    }

    private func tabMenu(for i: Int) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, enabled: Bool = true) {
            let mi = NSMenuItem(title: title, action: enabled ? sel : nil, keyEquivalent: "")
            mi.target = self
            mi.tag = i
            m.addItem(mi)
        }
        add("New Tab", #selector(menuNewTab(_:)))
        add("Duplicate Tab", #selector(menuDuplicateTab(_:)))
        m.addItem(.separator())
        add("Close Tab", #selector(menuCloseTab(_:)), enabled: tabs.count > 1)
        add("Close Other Tabs", #selector(menuCloseOthers(_:)), enabled: tabs.count > 1)
        add("Close Tabs to the Right", #selector(menuCloseRight(_:)), enabled: i < tabs.count - 1)
        return m
    }

    @objc private func menuNewTab(_ sender: NSMenuItem) { newTab(); activate() }

    @objc private func menuDuplicateTab(_ sender: NSMenuItem) {
        guard sender.tag < tabs.count else { return }
        saveActiveTabState()
        var copy = tabs[sender.tag]
        copy.forward = []
        tabs.insert(copy, at: sender.tag + 1)
        if activeTab > sender.tag { activeTab += 1 }
        switchTab(sender.tag + 1)
        activate()
    }

    @objc private func menuCloseTab(_ sender: NSMenuItem) { closeTab(at: sender.tag) }

    @objc private func menuCloseOthers(_ sender: NSMenuItem) {
        guard sender.tag < tabs.count else { return }
        if sender.tag == activeTab {
            tabs = [tabs[activeTab]]
            activeTab = 0
            updateTabBar()
            return
        }
        let keep = tabs[sender.tag]
        tabs = [keep]
        activeTab = -1
        switchTab(0)
    }

    @objc private func menuCloseRight(_ sender: NSMenuItem) {
        let i = sender.tag
        guard i < tabs.count - 1 else { return }
        tabs.removeSubrange((i + 1)...)
        if activeTab > i {
            activeTab = -1
            switchTab(i)
        } else {
            updateTabBar()
        }
    }

    // MARK: - Activation

    func activate() {
        window?.makeFirstResponder(focusView)
    }

    func didBecomeActive() {
        controller?.setActive(self)
    }

    // MARK: - Loading

    var cursorItem: FileItem? {
        let r = tableView.selectedRow
        return r >= 0 && r < items.count ? items[r] : nil
    }

    /// Marked items, or the item under the cursor when nothing is marked.
    var operationItems: [FileItem] {
        if !marked.isEmpty {
            return items.filter { marked.contains($0.name) }
        }
        if let c = cursorItem, !c.isParent { return [c] }
        return []
    }

    var previewURLs: [URL] {
        if let c = cursorItem, !c.isParent, c.url.isFileURL { return [c.url] }
        return []
    }

    /// Lists the current folder again. The listing runs on a background thread; when it is quick (the
    /// usual case for local folders) this call completes synchronously, otherwise the panel shows a loading
    /// state and finishes when the listing arrives. `completion` runs once the new items are shown.
    func reload(selectName: String? = nil, keepCursor: Bool = true, completion: (() -> Void)? = nil) {
        if let fs = remote {
            navigateRemote(fs, path: remotePath, select: selectName ?? (keepCursor ? cursorItem?.name : nil),
                           recordHistory: false) { _ in completion?() }
            return
        }
        let url = currentURL
        let sameDir = loadedURL?.standardizedFileURL == url.standardizedFileURL
        let wanted = selectName ?? (keepCursor && sameDir ? cursorItem?.name : nil)
        let oldRow = sameDir ? tableView.selectedRow : 0
        if !sameDir {
            marked.removeAll()
            dirSizes.removeAll()
            sizeJobs.values.forEach { $0.cancel() }
            sizeJobs.removeAll()
        }
        listingGeneration += 1
        let generation = listingGeneration
        startWatching()

        let showHidden = controller?.showHidden ?? false
        let key = sortKey, asc = ascending, foldersFirst = Settings.foldersFirst
        let knownSizes = dirSizes
        let box = ListingBox()
        let ready = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var list = (try? FileItem.list(url, showHidden: showHidden)) ?? []
            for it in list where it.isDirectory { it.dirSize = knownSizes[it.name] }
            if url.path != "/" { list.append(FileItem.parent(of: url)) }
            let sorted = Self.sort(list, key: key, ascending: asc, foldersFirst: foldersFirst)
            box.lock.lock()
            box.result = sorted
            let callback = box.onReady
            box.lock.unlock()
            if let callback { DispatchQueue.main.async { callback(sorted) } } else { ready.signal() }
        }

        let apply: ([FileItem]) -> Void = { [weak self] list in
            guard let self, self.listingGeneration == generation else { return }
            self.loading = false
            self.items = list
            self.marked = self.marked.intersection(Set(list.map(\.name)))
            self.loadedURL = url
            self.reloadAllViews()
            var row = 0
            if let wanted, let idx = list.firstIndex(where: { $0.name == wanted }) {
                row = idx
            } else {
                row = min(max(oldRow, 0), max(list.count - 1, 0))
            }
            self.setCursor(row)
            self.updateStatus()
            self.updateHeader()
            self.updateVolumeInfo()
            completion?()
        }

        if ready.wait(timeout: .now() + Self.synchronousListingTimeout) == .success {
            apply(box.result ?? [])
            return
        }
        box.lock.lock()
        if let result = box.result {
            box.lock.unlock()
            apply(result)
            return
        }
        box.onReady = apply
        box.lock.unlock()
        // Slow folder (huge, or on a network share): keep the old listing while refreshing the same folder,
        // show an empty panel when entering a new one, and never block the main thread.
        loading = true
        if !sameDir {
            items = []
            reloadAllViews()
            statusLabel.stringValue = "Loading…"
        }
        updateHeader()
    }

    private func sortItems(_ arr: [FileItem]) -> [FileItem] {
        Self.sort(arr, key: sortKey, ascending: ascending, foldersFirst: Settings.foldersFirst)
    }

    private static func sort(_ arr: [FileItem], key: SortKey, ascending asc: Bool, foldersFirst: Bool) -> [FileItem] {
        arr.sorted { a, b in
            if a.isParent != b.isParent { return a.isParent }
            if foldersFirst && a.isFolder != b.isFolder { return a.isFolder }
            var r: ComparisonResult
            switch key {
            case .name:
                r = a.name.localizedStandardCompare(b.name)
            case .ext:
                r = a.ext.localizedStandardCompare(b.ext)
            case .size:
                let sa = a.effectiveSize, sb = b.effectiveSize
                r = sa == sb ? .orderedSame : (sa < sb ? .orderedAscending : .orderedDescending)
            case .date:
                r = a.modified.compare(b.modified)
            case .attr:
                r = a.mode == b.mode ? .orderedSame : (a.mode < b.mode ? .orderedAscending : .orderedDescending)
            }
            if r == .orderedSame {
                r = a.name.localizedStandardCompare(b.name)
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
    }

    func setSort(_ key: SortKey, ascending asc: Bool? = nil) {
        let newAsc = asc ?? (key == sortKey ? !ascending : true)
        tableView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: newAsc)]
    }

    private func resort() {
        let name = cursorItem?.name
        items = sortItems(items)
        reloadAllViews()
        if let name, let idx = items.firstIndex(where: { $0.name == name }) { setCursor(idx) }
    }

    private func startWatching() {
        watcher?.cancel()
        watcher = nil
        guard !isRemote else { return }
        let fd = Darwin.open(currentURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link],
                                                            queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleRefresh() }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watcher = src
    }

    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            if !self.currentURL.isExistingDirectory {
                self.goToExistingAncestor()
            } else {
                self.reload()
            }
        }
    }

    private func goToExistingAncestor() {
        var u = currentURL
        while !u.isExistingDirectory && u.path != "/" { u = u.deletingLastPathComponent() }
        navigate(to: u, recordHistory: false)
    }

    // MARK: - Navigation

    @discardableResult
    func navigate(to url: URL, select: String? = nil, recordHistory: Bool = true) -> Bool {
        if !url.isFileURL {
            guard let fs = remote, url.scheme == fs.scheme else { NSSound.beep(); return false }
            navigateRemote(fs, path: url.path, select: select, recordHistory: recordHistory)
            return true
        }
        if isRemote { disconnectTab() }
        let target = url.standardizedFileURL
        guard target.isExistingDirectory else {
            NSSound.beep()
            return false
        }
        // opendir is enough to detect a protected (TCC) or unreadable folder; unlike listing it,
        // it is instant even on a slow network share with thousands of entries.
        if let dir = opendir(target.path) {
            closedir(dir)
        } else {
            let reason = String(cString: strerror(errno))
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Cannot access \(target.path)"
            a.informativeText = reason
                + "\n\nIf this is a protected location, FileAdmiral needs permission to open it."
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Open Permissions…")
            if a.runModal() == .alertSecondButtonReturn {
                PermissionsWindowController.show()
            }
            return false
        }
        if recordHistory && target != currentURL.standardizedFileURL {
            tabs[activeTab].back.append(currentURL)
            if tabs[activeTab].back.count > 100 { tabs[activeTab].back.removeFirst() }
            tabs[activeTab].forward.removeAll()
        }
        tabs[activeTab].url = target
        endQuickSearch()
        reload(selectName: select, keepCursor: false)
        updateTabBar()
        controller?.panelDidNavigate(self)
        return true
    }

    func goParent() {
        if let fs = remote {
            guard remotePath != "/" else { return }
            navigateRemote(fs, path: RemotePath.parent(remotePath), select: (remotePath as NSString).lastPathComponent,
                           recordHistory: true)
            return
        }
        guard currentURL.path != "/" else { return }
        navigate(to: currentURL.deletingLastPathComponent(), select: currentURL.lastPathComponent)
    }

    func goBack() {
        guard let prev = tabs[activeTab].back.popLast() else { NSSound.beep(); return }
        tabs[activeTab].forward.append(currentURL)
        let from = currentURL
        if !navigate(to: prev, select: from.deletingLastPathComponent() == prev ? from.lastPathComponent : nil, recordHistory: false) {
            tabs[activeTab].forward.removeLast()
        }
    }

    func goForward() {
        guard let next = tabs[activeTab].forward.popLast() else { NSSound.beep(); return }
        tabs[activeTab].back.append(currentURL)
        if !navigate(to: next, recordHistory: false) {
            tabs[activeTab].back.removeLast()
        }
    }

    var history: [URL] {
        tabs[activeTab].back
    }

    @objc func goHomeAction(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        activate()
    }

    @objc func goRootAction(_ sender: Any?) {
        navigate(to: URL(fileURLWithPath: "/"))
        activate()
    }

    @objc func goParentAction(_ sender: Any?) {
        goParent()
        activate()
    }

    func openCursor(enterPackage: Bool = false) {
        guard let it = cursorItem else { return }
        if it.isParent { goParent(); return }
        if let fs = remote {
            if it.isDirectory || it.isSymlink {
                // A link may point to a folder: try to open it, otherwise treat it as a file.
                navigateRemote(fs, path: it.url.path, select: nil, recordHistory: true) { [weak self] ok in
                    if !ok && !it.isDirectory { self?.controller?.openRemoteFile(it, from: self!) }
                }
            } else {
                controller?.openRemoteFile(it, from: self)
            }
            return
        }
        if it.isDirectory && (!it.isPackage || enterPackage) {
            navigate(to: it.url)
            return
        }
        if it.isArchive, controller?.browseArchive(it.url, from: self) == true {
            return
        }
        NSWorkspace.shared.open(it.url)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        openCursor()
    }

    // MARK: - Remote (FTP/SFTP)

    /// Shows a connection in this panel, in a new tab or the current one.
    func openRemote(_ fs: RemoteFileSystem, path: String, inNewTab: Bool) {
        if inNewTab {
            saveActiveTabState()
            let index = Settings.newTabAtEnd ? tabs.count : activeTab + 1
            tabs.insert(TabState(url: fs.url(for: path), remote: fs), at: index)
            activeTab = index
        } else {
            if let old = tabs[activeTab].remote, old !== fs { controller?.releaseConnection(old, closingTabOf: self, at: activeTab) }
            tabs[activeTab] = TabState(url: fs.url(for: path), remote: fs)
        }
        listingGeneration += 1 // a local listing still on its way must not land in the remote tab
        loadedURL = nil
        items = []
        marked.removeAll()
        reloadAllViews()
        navigateRemote(fs, path: path, select: nil, recordHistory: false)
        updateTabBar()
        controller?.panelDidNavigate(self)
    }

    /// Leaves the connection in the visible tab (the tab becomes a local tab again).
    func disconnectTab() {
        guard let fs = tabs[activeTab].remote else { return }
        controller?.releaseConnection(fs, closingTabOf: self, at: activeTab)
        tabs[activeTab].remote = nil
        tabs[activeTab].back = []
        tabs[activeTab].forward = []
        tabs[activeTab].url = FileManager.default.homeDirectoryForCurrentUser
        loadedURL = nil
    }

    var usesConnections: [RemoteFileSystem] { tabs.compactMap(\.remote) }

    /// Lists a remote folder in the background and shows it when the listing arrives.
    func navigateRemote(_ fs: RemoteFileSystem, path: String, select: String?, recordHistory: Bool,
                        completion: ((Bool) -> Void)? = nil) {
        let target = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : (path.isEmpty ? "/" : path)
        loading = true
        updateHeader()
        statusLabel.stringValue = "Loading \(fs.title)\(target) …"
        let tabIndex = activeTab
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try fs.list(target) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                // The user may have switched tabs meanwhile; only apply to the tab that asked.
                guard self.activeTab == tabIndex, self.tabs[tabIndex].remote === fs else {
                    completion?(false)
                    return
                }
                switch result {
                case .failure(let error):
                    self.updateHeader()
                    self.updateStatus()
                    if completion == nil {
                        Dialogs.error("Cannot open \(fs.title)\(target)", error.localizedDescription)
                    }
                    completion?(false)
                case .success(let entries):
                    let newURL = fs.url(for: target)
                    let sameDir = self.loadedURL == newURL
                    if recordHistory && newURL != self.currentURL {
                        self.tabs[tabIndex].back.append(self.currentURL)
                        self.tabs[tabIndex].forward.removeAll()
                    }
                    self.tabs[tabIndex].url = newURL
                    let wanted = select ?? (sameDir ? self.cursorItem?.name : nil)
                    let oldRow = sameDir ? self.tableView.selectedRow : 0
                    var list = entries.map { e in
                        FileItem(url: fs.url(for: RemotePath.join(target, e.name)), name: e.name, isDirectory: e.isDirectory,
                                 isParent: false, isSymlink: e.isLink, isHidden: e.name.hasPrefix("."), isPackage: false,
                                 size: e.size, modified: e.modified, mode: e.mode)
                    }
                    if !(self.controller?.showHidden ?? false) { list.removeAll { $0.isHidden } }
                    if target != "/" {
                        list.append(FileItem(url: fs.url(for: RemotePath.parent(target)), name: "..", isDirectory: true,
                                             isParent: true, isSymlink: false, isHidden: false, isPackage: false, size: 0,
                                             modified: Date.distantPast, mode: 0))
                    }
                    if !sameDir { self.marked.removeAll() }
                    self.items = self.sortItems(list)
                    self.marked = self.marked.intersection(Set(self.items.map(\.name)))
                    self.loadedURL = newURL
                    self.endQuickSearch()
                    self.reloadAllViews()
                    if let wanted, let idx = self.items.firstIndex(where: { $0.name == wanted }) {
                        self.setCursor(idx)
                    } else {
                        self.setCursor(min(max(oldRow, 0), max(self.items.count - 1, 0)))
                    }
                    self.updateStatus()
                    self.updateHeader()
                    self.updateVolumeInfo()
                    self.updateTabBar()
                    self.controller?.panelDidNavigate(self)
                    completion?(true)
                }
            }
        }
    }

    // MARK: - Tabs

    func newTab(url: URL? = nil) {
        saveActiveTabState()
        let index = Settings.newTabAtEnd ? tabs.count : activeTab + 1
        tabs.insert(TabState(url: url ?? currentURL), at: index)
        switchTab(index)
    }

    /// Remembers cursor and marks of the visible tab, so they come back when returning to it.
    private func saveActiveTabState() {
        guard activeTab >= 0 && activeTab < tabs.count else { return }
        tabs[activeTab].cursorName = cursorItem?.name
        tabs[activeTab].markedNames = marked
    }

    func closeTab(at index: Int? = nil) {
        let i = index ?? activeTab
        guard tabs.count > 1, i >= 0, i < tabs.count else { NSSound.beep(); return }
        if let fs = tabs[i].remote { controller?.releaseConnection(fs, closingTabOf: self, at: i) }
        if i != activeTab {
            // Closing a background tab doesn't touch the visible one.
            tabs.remove(at: i)
            if i < activeTab { activeTab -= 1 }
            updateTabBar()
            return
        }
        tabs.remove(at: i)
        activeTab = -1
        switchTab(min(i, tabs.count - 1))
    }

    func switchTab(_ i: Int) {
        guard i >= 0, i < tabs.count else { return }
        if i == activeTab && loadedURL != nil {
            updateTabBar()
            return
        }
        saveActiveTabState()
        activeTab = i
        loadedURL = nil
        if !isRemote && !currentURL.isExistingDirectory {
            tabs[i].url = FileManager.default.homeDirectoryForCurrentUser
        }
        let marks = tabs[i].markedNames
        reload(selectName: tabs[i].cursorName, keepCursor: false) { [weak self] in
            if !marks.isEmpty { self?.setMarked(marks) }
        }
        updateTabBar()
        controller?.panelDidNavigate(self)
    }

    func nextTab() { switchTab((activeTab + 1) % tabs.count) }
    func prevTab() { switchTab((activeTab - 1 + tabs.count) % tabs.count) }

    func exportTabs() -> ([TabState], Int) {
        saveActiveTabState()
        return (tabs, activeTab)
    }

    func importTabs(_ t: [TabState], active: Int) {
        tabs = t
        activeTab = -1
        loadedURL = nil
        switchTab(min(max(active, 0), t.count - 1))
    }

    // MARK: - Cursor & marking

    func setCursor(_ row: Int) {
        guard !items.isEmpty else { return }
        let r = min(max(row, 0), items.count - 1)
        tableView.selectRowIndexes([r], byExtendingSelection: false)
        tableView.scrollRowToVisible(r)
        if viewMode == .thumbnails {
            let ip = IndexPath(item: r, section: 0)
            grid.selectionIndexPaths = [ip]
            grid.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
            refreshVisibleTiles()
        }
    }

    /// Moves the cursor by `delta` rows (thumbnail grid arrows); with `mark` it marks like Shift+arrows.
    func moveCursorBy(_ delta: Int, mark: Bool) {
        if mark { markStep(delta) } else { setCursor(tableView.selectedRow + delta) }
    }

    /// Redraws the table and, in thumbnail mode, the grid.
    func reloadAllViews() {
        tableView.reloadData()
        if viewMode == .thumbnails { grid.reloadData() }
    }

    // MARK: - Thumbnails

    private func buildGrid() {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        grid.collectionViewLayout = layout
        grid.panel = self
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = false
        grid.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.id)
        grid.registerForDraggedTypes([.fileURL])
        grid.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        grid.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.borderType = .bezelBorder
        gridScroll.isHidden = true
        updateThumbnailSize()
    }

    private func updateThumbnailSize() {
        guard let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let side = Settings.thumbnailSize.points
        layout.itemSize = NSSize(width: side + 12, height: side + 46)
    }

    @objc private func viewSwitchChanged(_ sender: NSSegmentedControl) {
        setViewMode([ViewMode.details, .thumbnails, .tree][max(0, min(sender.selectedSegment, 2))])
        activate()
    }

    /// Leaves the folder tree, optionally opening the chosen folder in this panel.
    func leaveTree(openingFolder url: URL?) {
        setViewMode(modeBeforeTree)
        if let url { navigate(to: url) }
        activate()
    }

    func setViewMode(_ mode: ViewMode) {
        if mode == .tree && isRemote {
            NSSound.beep()
            viewSwitch.selectedSegment = viewMode == .thumbnails ? 1 : 0
            return
        }
        viewSwitch.selectedSegment = mode == .thumbnails ? 1 : (mode == .tree ? 2 : 0)
        guard mode != viewMode else { return }
        let hadFocus = window?.firstResponder === focusView
        if mode == .tree { modeBeforeTree = viewMode }
        viewMode = mode
        scrollView.isHidden = mode != .details || isQuickView
        gridScroll.isHidden = mode != .thumbnails || isQuickView
        treeScroll.isHidden = mode != .tree || isQuickView
        let row = tableView.selectedRow
        if mode == .thumbnails { grid.reloadData() }
        if mode == .tree { tree.show(currentURL) }
        setCursor(row)
        if hadFocus { activate() }
        // The tree is a temporary mode; restarting returns to the list or thumbnails.
        if mode != .tree { UserDefaults.standard.set(mode.rawValue, forKey: key("ViewMode")) }
    }

    /// The view that takes keyboard focus for this panel.
    var focusView: NSView {
        switch viewMode {
        case .details: return tableView
        case .thumbnails: return grid
        case .tree: return tree
        }
    }

    /// Updates cursor/mark/emphasis of the visible tiles without reloading thumbnails.
    func refreshVisibleTiles() {
        guard viewMode == .thumbnails else { return }
        let cursor = tableView.selectedRow
        let emphasized = window?.firstResponder === grid && window?.isKeyWindow == true
        for case let item as ThumbnailItem in grid.visibleItems() {
            guard let i = grid.indexPath(for: item)?.item, i < items.count else { continue }
            item.tile.isCursor = i == cursor
            item.tile.isEmphasized = emphasized
            item.tile.isMarked = marked.contains(items[i].name)
        }
    }

    func refreshThumbnailEmphasis() { refreshVisibleTiles() }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ThumbnailItem.id, for: indexPath) as! ThumbnailItem
        guard indexPath.item < items.count else { return item }
        let it = items[indexPath.item]
        let tile = item.tile
        let size = Settings.thumbnailSize.points
        tile.representedPath = it.url.absoluteString
        tile.label.stringValue = it.isParent ? ".." : it.name
        tile.isDim = it.isHidden
        tile.isMarked = marked.contains(it.name)
        tile.isCursor = indexPath.item == tableView.selectedRow
        tile.isEmphasized = window?.firstResponder === grid && window?.isKeyWindow == true
        if let cached = ThumbnailCache.shared.cached(it, size: size) {
            tile.imageView.image = cached
        } else {
            tile.imageView.image = icon(for: it)
            let path = tile.representedPath
            ThumbnailCache.shared.request(it, size: size, scale: window?.backingScaleFactor ?? 2) { [weak tile] image in
                if tile?.representedPath == path { tile?.imageView.image = image }
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < items.count else { return nil }
        let it = items[indexPath.item]
        return it.isParent || !it.url.isFileURL ? nil : it.url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let mods = NSEvent.modifierFlags
        return mods.contains(.shift) || mods.contains(.command) ? .move : .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        acceptDroppedFiles(draggingInfo, onRow: dropOperation == .on ? indexPath.item : -1)
    }

    // MARK: - Quick View panel

    /// Shows a live preview of `item` (from the other panel) instead of this panel's file list.
    func showQuickView(_ item: FileItem?) {
        if !isQuickView {
            isQuickView = true
            scrollView.isHidden = true
            gridScroll.isHidden = true
            treeScroll.isHidden = true
            quickViewContainer.isHidden = false
        }
        if quickPreview == nil, let qp = QLPreviewView(frame: quickViewContainer.bounds, style: .normal) {
            qp.autoresizingMask = [.width, .height]
            qp.shouldCloseWithWindow = false
            quickViewContainer.addSubview(qp, positioned: .below, relativeTo: quickMessage)
            quickPreview = qp
        }
        if let item, !item.isParent, item.url.isFileURL {
            quickPreview?.isHidden = false
            quickPreview?.previewItem = item.url as NSURL
            quickMessage.stringValue = ""
            pathHeader.configure(text: " Quick View: " + item.url.abbreviatedPath, segments: [])
            let size = item.isDirectory ? (item.dirSize.map(Fmt.bytes) ?? "folder") : Fmt.bytes(item.size)
            statusLabel.stringValue = "\(item.name)   \(size)   \(Fmt.date(item.modified))   (⌃Q closes Quick View)"
        } else {
            quickPreview?.previewItem = nil
            quickPreview?.isHidden = true
            quickMessage.stringValue = item?.url.isFileURL == false ? "No preview for files on FTP/SFTP servers.\nUse F3 to view."
                                                                    : "Nothing to preview"
            pathHeader.configure(text: " Quick View", segments: [])
            statusLabel.stringValue = "(⌃Q closes Quick View)"
        }
    }

    func hideQuickView() {
        guard isQuickView else { return }
        isQuickView = false
        quickPreview?.previewItem = nil
        quickViewContainer.isHidden = true
        scrollView.isHidden = viewMode != .details
        gridScroll.isHidden = viewMode != .thumbnails
        treeScroll.isHidden = viewMode != .tree
        updateHeader()
        updateStatus()
    }

    func select(name: String) {
        if let idx = items.firstIndex(where: { $0.name == name }) { setCursor(idx) }
    }

    private var pageRows: Int {
        max(1, Int(scrollView.contentView.bounds.height / (tableView.rowHeight + tableView.intercellSpacing.height)) - 1)
    }

    /// Whether the current Shift gesture marks (true) or unmarks (false) files. Like in TC it is decided by
    /// the file the gesture starts on: starting on a marked file unmarks. Reset when Shift is released.
    private var shiftMarkMode: Bool?

    func endShiftGesture() {
        shiftMarkMode = nil
    }

    private func shiftMode(startingAt row: Int) -> Bool {
        if let m = shiftMarkMode { return m }
        var start = row
        // ".." can't be marked; decide by the next row instead.
        if start >= 0, start < items.count, items[start].isParent { start += 1 }
        let m = !(start >= 0 && start < items.count && marked.contains(items[start].name))
        shiftMarkMode = m
        return m
    }

    private func setMarks(_ rows: ClosedRange<Int>, on: Bool) {
        for r in rows where r >= 0 && r < items.count && !items[r].isParent {
            if on { marked.insert(items[r].name) } else { marked.remove(items[r].name) }
        }
        reloadRows(IndexSet(integersIn: max(rows.lowerBound, 0)...min(rows.upperBound, items.count - 1)))
        updateStatus()
    }

    private func moveCursor(to target: Int, extend: Bool) {
        guard !items.isEmpty else { return }
        let from = tableView.selectedRow
        let to = min(max(target, 0), items.count - 1)
        if extend && from >= 0 {
            let on = shiftMode(startingAt: from)
            // The target row itself is left as is, so the next Shift+arrow continues from it,
            // except at the top/bottom of the list where there is nowhere further to go.
            let atEdge = to == 0 || to == items.count - 1
            if to > from {
                setMarks(from...(atEdge ? to : to - 1), on: on)
            } else if to < from {
                setMarks((atEdge ? to : to + 1)...from, on: on)
            }
        }
        setCursor(to)
    }

    private func markStep(_ delta: Int) {
        let r = tableView.selectedRow
        guard r >= 0 else { return }
        setMarks(r...r, on: shiftMode(startingAt: r))
        setCursor(r + delta)
    }

    /// Redraws all rows in place after marks changed; unlike reloadData it never moves the cursor.
    private func redrawMarks() {
        guard !items.isEmpty else { return }
        reloadRows(IndexSet(integersIn: 0..<items.count))
    }

    private func reloadRows(_ rows: IndexSet) {
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        refreshVisibleTiles()
    }

    func toggleMark(row: Int) {
        guard row >= 0, row < items.count, !items[row].isParent else { return }
        let n = items[row].name
        if marked.contains(n) { marked.remove(n) } else { marked.insert(n) }
        reloadRows([row])
        updateStatus()
    }

    /// Shift+click: marks the range, or unmarks it when the clicked file is already marked.
    func markRange(from: Int, to: Int) {
        guard from >= 0, to >= 0, to < items.count else { return }
        let on = !marked.contains(items[to].name)
        setMarks(min(from, to)...max(from, to), on: on)
    }

    private func toggleCursorMark(moveDown: Bool, calcSize: Bool) {
        let r = tableView.selectedRow
        guard r >= 0 else { return }
        let it = items[r]
        if !it.isParent {
            let wasMarked = marked.contains(it.name)
            toggleMark(row: r)
            if calcSize && !wasMarked && it.isFolder && it.dirSize == nil {
                calculateSize(of: it)
            }
        }
        if moveDown { setCursor(r + 1) }
    }

    func markAll(_ on: Bool) {
        if on {
            marked = Set(items.filter { !$0.isParent }.map(\.name))
        } else {
            marked.removeAll()
        }
        redrawMarks()
        updateStatus()
    }

    func invertMarks() {
        for it in items where !it.isParent && !it.isFolder {
            if marked.contains(it.name) { marked.remove(it.name) } else { marked.insert(it.name) }
        }
        redrawMarks()
        updateStatus()
    }

    /// Select/unselect by mask. A mask ending with "/" applies to folders.
    func mark(mask: String, on: Bool) {
        var m = mask
        let folders = m.hasSuffix("/")
        if folders { m.removeLast() }
        let fm = FileMask(m)
        for it in items where !it.isParent && it.isFolder == folders && fm.matches(it.name) {
            if on { marked.insert(it.name) } else { marked.remove(it.name) }
        }
        redrawMarks()
        updateStatus()
    }

    func setMarked(_ names: Set<String>) {
        marked = names.intersection(Set(items.map(\.name)))
        redrawMarks()
        updateStatus()
    }

    func unmark(_ names: [String]) {
        for n in names { marked.remove(n) }
        redrawMarks()
        updateStatus()
    }

    // MARK: - Directory sizes

    func calculateSize(of item: FileItem) {
        guard item.isDirectory, item.url.isFileURL, sizeJobs[item.name] == nil else { return }
        let flag = CancelFlag()
        sizeJobs[item.name] = flag
        let url = item.url, name = item.name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let size = FileItem.directorySize(url, cancel: flag)
            DispatchQueue.main.async {
                guard let self, !flag.isCancelled else { return }
                self.sizeJobs[name] = nil
                self.dirSizes[name] = size
                if let idx = self.items.firstIndex(where: { $0.name == name }) {
                    self.items[idx].dirSize = size
                    self.reloadRows([idx])
                }
                self.updateStatus()
            }
        }
    }

    func calculateAllSizes() {
        for it in items where it.isDirectory && !it.isParent && it.dirSize == nil {
            calculateSize(of: it)
        }
    }

    // MARK: - Quick search

    private func isPrintable(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { v in
            v.value >= 0x20 && v.value != 0x7F && !(0xF700...0xF8FF).contains(v.value)
        }
    }

    private func quickSearchType(_ s: String) {
        let previous = quickSearch
        quickSearch += s
        if !quickJump(from: 0, forward: true) {
            quickSearch = previous
            NSSound.beep()
        }
        showQuickSearch()
    }

    /// Moves the cursor to the next item whose name starts with the search text.
    @discardableResult
    private func quickJump(from start: Int, forward: Bool) -> Bool {
        guard !items.isEmpty, !quickSearch.isEmpty else { return false }
        let needle = quickSearch.lowercased()
        let n = items.count
        for k in 0..<n {
            let idx = forward ? (start + k + n) % n : (start - k + n * 2) % n
            if items[idx].name.lowercased().hasPrefix(needle) {
                setCursor(idx)
                return true
            }
        }
        return false
    }

    private func showQuickSearch() {
        if quickSearch.isEmpty {
            quickSearchLabel.isHidden = true
        } else {
            quickSearchLabel.stringValue = " Quick search: \(quickSearch)"
            quickSearchLabel.isHidden = false
        }
    }

    func endQuickSearch() {
        quickSearch = ""
        quickSearchLabel.isHidden = true
    }

    // MARK: - Keyboard

    func handleKey(_ e: NSEvent) -> Bool {
        guard let c = controller else { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = mods.contains(.shift), cmd = mods.contains(.command)
        let opt = mods.contains(.option), ctrl = mods.contains(.control)
        let code = e.keyCode

        if !quickSearch.isEmpty {
            switch code {
            case 51:
                quickSearch.removeLast()
                if quickSearch.isEmpty { endQuickSearch() } else { quickJump(from: 0, forward: true); showQuickSearch() }
                return true
            case 125:
                quickJump(from: tableView.selectedRow + 1, forward: true)
                return true
            case 126:
                quickJump(from: tableView.selectedRow - 1, forward: false)
                return true
            case 53:
                endQuickSearch()
                return true
            default:
                if !cmd && !ctrl, let s = e.characters, isPrintable(s) {
                    quickSearchType(s)
                    return true
                }
                endQuickSearch()
            }
        }

        switch code {
        case 48: // Tab
            if ctrl { shift ? prevTab() : nextTab() } else { c.switchPanel() }
            return true
        case 36, 76: // Return / Enter
            if cmd && shift {
                if let it = cursorItem { c.insertIntoCommandLine(it.url.path) }
            } else if cmd {
                if let it = cursorItem, !it.isParent { c.insertIntoCommandLine(it.name) }
            } else if opt && shift {
                calculateAllSizes()
            } else if !c.commandLineText.isEmpty {
                c.executeCommandLine(nil)
            } else {
                openCursor()
            }
            return true
        case 51: // Backspace
            if cmd {
                c.deleteFiles(permanent: opt)
            } else if Settings.typingAction == .commandLine && !c.commandLineText.isEmpty {
                c.deleteCommandLineCharacter()
            } else {
                goParent()
            }
            return true
        case 117: // Forward delete
            c.deleteFiles(permanent: shift)
            return true
        case 49 where !cmd && !ctrl: // Space
            toggleCursorMark(moveDown: false, calcSize: true)
            return true
        case 114: // Insert (Help)
            toggleCursorMark(moveDown: true, calcSize: false)
            return true
        case 115: moveCursor(to: 0, extend: shift); return true // Home
        case 119: moveCursor(to: items.count - 1, extend: shift); return true // End
        case 116: moveCursor(to: tableView.selectedRow - pageRows, extend: shift); return true // PgUp
        case 121: // PgDn
            if cmd { openCursor(enterPackage: true) } else { moveCursor(to: tableView.selectedRow + pageRows, extend: shift) }
            return true
        case 125: // Down
            if opt && !cmd { c.showHistory(for: self); return true }
            if cmd { openCursor(enterPackage: opt); return true }
            if shift { markStep(1); return true }
            return false
        case 126: // Up
            if cmd { goParent(); return true }
            if shift { markStep(-1); return true }
            return false
        case 123 where cmd: c.openCursorIn(side: .left); return true
        case 124 where cmd: c.openCursorIn(side: .right); return true
        case 53: // Esc
            c.clearCommandLine()
            return true
        case 120: c.renameFile(nil); return true // F2 (rename in place, as in Finder/Explorer; reread is ⌘R)
        case 99: c.viewFile(nil); return true // F3
        case 118: shift ? c.newFile(nil) : c.editFile(nil); return true // F4
        case 96: // F5
            if opt { c.packFiles(nil) } else if shift { c.copyInPlace(nil) } else { c.copyFiles(nil) }
            return true
        case 97: shift ? c.renameFile(nil) : c.moveFiles(nil); return true // F6
        case 98: opt ? c.searchFiles(nil) : c.makeDirectory(nil); return true // F7
        case 100: c.deleteFiles(permanent: shift); return true // F8
        case 101: if opt { c.unpackFiles(nil) }; return true // F9
        default:
            break
        }

        if ctrl && !cmd && !opt, let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...7).contains(n) {
            c.toggleStandardTag(n - 1)
            return true
        }

        if cmd && !ctrl && !opt, let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
            switchTab(n == 9 ? tabs.count - 1 : min(n - 1, tabs.count - 1))
            return true
        }

        if Settings.typingAction == .commandLine && !cmd && !ctrl {
            // Classic TC: typed characters go to the command line; ⌥+letter starts quick search.
            if opt, let s = e.charactersIgnoringModifiers, isPrintable(s) {
                quickSearchType(s)
                return true
            }
            if let s = e.characters, isPrintable(s) {
                if c.commandLineText.isEmpty, ["+", "-", "*"].contains(s) {
                    return handleSelectionKey(s, c)
                }
                c.typeIntoCommandLine(s)
                return true
            }
            return false
        }

        if !cmd && !ctrl, let s = e.characters, isPrintable(s) {
            if ["+", "-", "*"].contains(s) { return handleSelectionKey(s, c) }
            quickSearchType(s)
            return true
        }
        return false
    }

    private func handleSelectionKey(_ s: String, _ c: MainWindowController) -> Bool {
        switch s {
        case "+": c.selectGroup(nil)
        case "-": c.unselectGroup(nil)
        default: c.invertSelection(nil)
        }
        return true
    }

    // MARK: - Pasteboard

    func copyToPasteboard() {
        guard !isRemote else { NSSound.beep(); return }
        let urls = operationItems.map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls)
    }

    func pasteFromPasteboard() {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { NSSound.beep(); return }
        controller?.performTransfer(urls, to: currentURL, move: false)
    }

    // MARK: - Context menu

    func contextMenu() -> NSMenu {
        let m = NSMenu()
        guard let it = cursorItem, let c = controller else { return m }

        func add(_ title: String, _ sel: Selector, target: AnyObject, key: String = "", mods: NSEvent.ModifierFlags = []) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            mi.keyEquivalentModifierMask = mods
            mi.target = target
            m.addItem(mi)
        }

        add("Open", #selector(menuOpen(_:)), target: self, key: "\r")
        if isRemote {
            m.addItem(.separator())
            add("View", #selector(MainWindowController.viewFile(_:)), target: c, key: fkey(3))
            add("Edit (uploads on save)", #selector(MainWindowController.editFile(_:)), target: c, key: fkey(4))
            m.addItem(.separator())
            add("Download / Copy…", #selector(MainWindowController.copyFiles(_:)), target: c, key: fkey(5))
            add("Move…", #selector(MainWindowController.moveFiles(_:)), target: c, key: fkey(6))
            add("Rename…", #selector(MainWindowController.renameFile(_:)), target: c, key: fkey(2), mods: [])
            add("Delete", #selector(MainWindowController.deleteToTrash(_:)), target: c, key: fkey(8))
            m.addItem(.separator())
            add("Copy Name", #selector(MainWindowController.copyNames(_:)), target: c)
            add("Copy Full URL", #selector(MainWindowController.copyFullNames(_:)), target: c)
            add("Disconnect", #selector(MainWindowController.disconnect(_:)), target: c)
            return m
        }
        if !it.isParent && !it.isFolder {
            let sub = NSMenu()
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: it.url)
            for app in apps.prefix(25) {
                let mi = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: #selector(openWithApp(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = app
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                mi.image = icon
                sub.addItem(mi)
            }
            if !apps.isEmpty { sub.addItem(.separator()) }
            let other = NSMenuItem(title: "Other…", action: #selector(openWithOther(_:)), keyEquivalent: "")
            other.target = self
            sub.addItem(other)
            let owi = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            owi.submenu = sub
            m.addItem(owi)
        }
        if it.isPackage {
            add("Show Package Contents", #selector(menuShowPackage(_:)), target: self)
        }
        if it.isFolder && !it.isParent {
            add("Open in New Tab", #selector(menuOpenInTab(_:)), target: self)
            add("Calculate Size", #selector(menuCalcSize(_:)), target: self)
        }
        m.addItem(.separator())
        add("View", #selector(MainWindowController.viewFile(_:)), target: c, key: fkey(3))
        add("Edit", #selector(MainWindowController.editFile(_:)), target: c, key: fkey(4))
        add("Quick Look", #selector(MainWindowController.quickLook(_:)), target: c, key: "y", mods: .command)
        m.addItem(.separator())
        add("Copy…", #selector(MainWindowController.copyFiles(_:)), target: c, key: fkey(5))
        add("Move…", #selector(MainWindowController.moveFiles(_:)), target: c, key: fkey(6))
        add("Rename…", #selector(MainWindowController.renameFile(_:)), target: c, key: fkey(2), mods: [])
        add("Move to Trash", #selector(MainWindowController.deleteToTrash(_:)), target: c, key: fkey(8))
        m.addItem(.separator())
        if it.isArchive {
            add("Unpack…", #selector(MainWindowController.unpackFiles(_:)), target: c, key: fkey(9), mods: .option)
        }
        add("Pack…", #selector(MainWindowController.packFiles(_:)), target: c, key: fkey(5), mods: .option)
        m.addItem(.separator())
        add("Copy Name", #selector(MainWindowController.copyNames(_:)), target: c)
        add("Copy Full Path", #selector(MainWindowController.copyFullNames(_:)), target: c)
        add("Reveal in Finder", #selector(MainWindowController.revealInFinder(_:)), target: c)
        let shareItem = NSSharingServicePicker(items: operationItems.map(\.url)).standardShareMenuItem
        m.addItem(shareItem)
        let tagsItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        tagsItem.submenu = c.tagsMenu()
        tagsItem.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        m.addItem(tagsItem)
        add("Get Info", #selector(MainWindowController.getInfo(_:)), target: c, key: "i", mods: .command)
        add("Open Terminal Here", #selector(MainWindowController.openTerminal(_:)), target: c)
        return m
    }

    @objc private func menuOpen(_ sender: Any?) { openCursor() }
    @objc private func menuShowPackage(_ sender: Any?) { openCursor(enterPackage: true) }
    @objc private func menuOpenInTab(_ sender: Any?) {
        if let it = cursorItem { newTab(url: it.url) }
    }
    @objc private func menuCalcSize(_ sender: Any?) {
        if let it = cursorItem { calculateSize(of: it) }
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL, let it = cursorItem else { return }
        NSWorkspace.shared.open([it.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openWithOther(_ sender: Any?) {
        guard let it = cursorItem else { return }
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.prompt = "Open"
        if p.runModal() == .OK, let app = p.url {
            NSWorkspace.shared.open([it.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> FileCellView {
        let cell = FileCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.font = Theme.font
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        if id.rawValue == "name" {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(iv)
            cell.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
            ])
            // Tag dots follow the name; the name truncates first when space is short.
            let dots = TagDotsView()
            dots.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(dots)
            cell.tagDots = dots
            tf.setContentHuggingPriority(.required, for: .horizontal)
            tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([
                dots.leadingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 4),
                dots.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
                dots.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                dots.heightAnchor.constraint(equalToConstant: 11),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        } else {
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor).isActive = true
        }
        if id.rawValue == "size" { tf.alignment = .right }
        NSLayoutConstraint.activate([
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < items.count else { return nil }
        let id = col.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? FileCellView) ?? makeCell(id)
        let it = items[row]
        let text: String
        switch id.rawValue {
        case "name":
            if it.isParent {
                text = "[..]"
            } else if it.isFolder {
                text = Settings.folderBrackets ? "[\(it.name)]" : it.name
            } else {
                text = it.baseName
            }
            cell.imageView?.image = Settings.showIcons ? icon(for: it) : nil
        case "ext":
            text = it.ext
        case "size":
            if it.isDirectory {
                if let s = it.dirSize { text = Fmt.size(s) } else { text = it.isPackage ? "<PKG>" : "<DIR>" }
            } else {
                text = Fmt.size(it.size)
            }
        case "date":
            // Remote listings may not provide a date (e.g. for "..").
            text = it.modified == .distantPast ? "" : Fmt.date(it.modified)
        case "attr":
            text = it.isParent && !it.url.isFileURL ? "" : Fmt.permissions(it.mode, isDir: it.isDirectory, isLink: it.isSymlink)
        default:
            text = ""
        }
        cell.textField?.stringValue = text
        cell.isDim = it.isHidden
        cell.isFolder = it.isFolder || it.isParent
        cell.tagDots?.colors = it.tags.compactMap(\.color)
        cell.textField?.font = id.rawValue == "attr" ? Theme.attrFont : Theme.font
        cell.isMarked = marked.contains(it.name)
        cell.toolTip = id.rawValue == "name" && it.isSymlink && it.url.isFileURL
            ? "→ " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: it.url.path)) ?? "?")
            : nil
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sd = tableView.sortDescriptors.first, let k = SortKey(rawValue: sd.key ?? "") else { return }
        sortKey = k
        ascending = sd.ascending
        resort()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FileRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
        controller?.cursorDidMove(in: self)
    }

    private func icon(for it: FileItem) -> NSImage? {
        let key: String
        if it.isParent {
            key = "/parent"
        } else if (it.isPackage || it.isSymlink) && it.url.isFileURL {
            key = it.url.path
        } else if it.isDirectory {
            key = "/dir"
        } else {
            key = "." + it.ext.lowercased()
        }
        if let img = iconCache[key] { return img }
        let img: NSImage
        if it.isParent {
            img = Self.parentFolderIcon
        } else if (it.isPackage || it.isSymlink) && it.url.isFileURL {
            img = NSWorkspace.shared.icon(forFile: it.url.path)
        } else if it.isDirectory {
            img = NSWorkspace.shared.icon(for: .folder)
        } else {
            let type = it.ext.isEmpty ? UTType.data : (UTType(filenameExtension: it.ext) ?? .data)
            img = NSWorkspace.shared.icon(for: type)
        }
        img.size = NSSize(width: 16, height: 16)
        if iconCache.count > 2000 { iconCache.removeAll() }
        iconCache[key] = img
        return img
    }

    // MARK: Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let it = items[row]
        return it.isParent || !it.url.isFileURL ? nil : it.url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        // Dragging a marked file drags all marked files, like in TC.
        guard let row = rowIndexes.first, row < items.count, marked.contains(items[row].name) else { return }
        let urls = items.filter { marked.contains($0.name) }.map { $0.url as NSURL }
        guard urls.count > 1 else { return }
        session.draggingPasteboard.clearContents()
        session.draggingPasteboard.writeObjects(urls)
        session.draggingFormation = .pile
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .on, row >= 0, row < items.count, items[row].isFolder {
            // drop into that folder
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        let mods = NSEvent.modifierFlags
        return mods.contains(.shift) || mods.contains(.command) ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        acceptDroppedFiles(info, onRow: dropOperation == .on ? row : -1)
    }

    /// Copies (or with Shift/⌘ moves) dropped files into this panel's folder, or into the folder at `row`.
    func acceptDroppedFiles(_ info: NSDraggingInfo, onRow row: Int) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        var dest = currentURL
        if row >= 0, row < items.count, items[row].isFolder, !items[row].isParent { dest = items[row].url }
        let filtered = urls.filter { $0.deletingLastPathComponent().standardizedFileURL != dest.standardizedFileURL && $0 != dest }
        guard !filtered.isEmpty else { return false }
        let mods = NSEvent.modifierFlags
        controller?.performTransfer(filtered, to: dest, move: mods.contains(.shift) || mods.contains(.command))
        return true
    }
}

/// Character used as a menu key equivalent for function key Fn.
func fkey(_ n: Int) -> String {
    String(Character(UnicodeScalar(UInt32(NSF1FunctionKey + n - 1))!))
}
