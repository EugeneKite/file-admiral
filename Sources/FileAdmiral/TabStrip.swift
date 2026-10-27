import AppKit

/// Folder tabs above a file panel: one tab per folder, a close button on each tab and a "+" button.
final class TabStrip: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var menuForTab: ((Int) -> NSMenu?)?

    private let stack = NSStackView()
    /// Color of the "+" symbol (nil = default).
    var plusTint: NSColor? { didSet { plusButton.contentTintColor = plusTint } }
    private let plusButton = PlusButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .bottom
        stack.setClippingResistancePriority(.fittingSizeCompression, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")?.withSymbolConfiguration(config)
        plusButton.isBordered = false
        plusButton.bezelStyle = .smallSquare
        plusButton.toolTip = "New tab (⌘T) — or drop a folder here to open it in a new tab"
        plusButton.target = self
        plusButton.action = #selector(plusClicked(_:))
        plusButton.refusesFirstResponder = true
        plusButton.onDropFolder = { [weak self] url in self?.onOpenInNewTab?(url) }
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plusButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            plusButton.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 3),
            plusButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 22),
            plusButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// Rebuilds the tabs. `titles` are (name, full path) pairs.
    func update(titles: [(String, String)], active: Int, panelActive: Bool) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, t) in titles.enumerated() {
            let tab = TabItemView(title: t.0, tooltip: t.1, index: i, isActive: i == active,
                                  panelActive: panelActive, closable: titles.count > 1)
            tab.onSelect = { [weak self] in self?.onSelect?($0) }
            tab.onClose = { [weak self] in self?.onClose?($0) }
            tab.menuProvider = { [weak self] in self?.menuForTab?($0) }
            stack.addArrangedSubview(tab)
            tab.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: -1).isActive = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onNew?() }
    }

    @objc private func plusClicked(_ sender: Any?) {
        onNew?()
    }
}

/// "+" button that also accepts a dropped folder.
private final class PlusButton: NSButton {
    var onDropFolder: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func folders(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).filter(\.isExistingDirectory)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        folders(sender).isEmpty ? [] : .link
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let f = folders(sender)
        f.forEach { onDropFolder?($0) }
        return !f.isEmpty
    }
}

private final class TabItemView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    private let index: Int
    private let isActive: Bool
    private let panelActive: Bool
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var hovering = false {
        didSet {
            closeButton.isHidden = !(closable && (hovering || isActive))
            needsDisplay = true
        }
    }
    private let closable: Bool

    init(title: String, tooltip: String, index: Int, isActive: Bool, panelActive: Bool, closable: Bool) {
        self.index = index
        self.isActive = isActive
        self.panelActive = panelActive
        self.closable = closable
        super.init(frame: .zero)
        toolTip = tooltip

        label.stringValue = title
        label.font = isActive ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 11)
        label.textColor = isActive ? Theme.current.text : Theme.current.inactiveHeaderText
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?.withSymbolConfiguration(config)
        closeButton.isBordered = false
        closeButton.bezelStyle = .smallSquare
        closeButton.toolTip = "Close tab (⌘W)"
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.refusesFirstResponder = true
        closeButton.isHidden = !(closable && isActive)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        let minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        minWidth.priority = NSLayoutConstraint.Priority(rawValue: 240) // below the split view's holding priority
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 3),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
            widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            minWidth,
        ])
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
        let r = bounds.insetBy(dx: 0.5, dy: 0)
        let path = NSBezierPath()
        let radius: CGFloat = 5
        path.move(to: NSPoint(x: r.minX, y: r.minY))
        path.line(to: NSPoint(x: r.minX, y: r.maxY - radius))
        path.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: r.maxX - radius, y: r.maxY))
        path.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: r.maxX, y: r.minY))

        let t = Theme.current
        if isActive {
            t.panelBackground.setFill()
        } else if hovering {
            t.inactiveHeader.blended(withFraction: 0.4, of: t.panelBackground)?.setFill()
        } else {
            t.inactiveHeader.setFill()
        }
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        if isActive {
            (panelActive ? t.activeHeader : t.hiddenText).setFill()
            NSRect(x: r.minX + 3, y: r.maxY - 2.5, width: r.width - 6, height: 2.5).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(index)
    }

    override func otherMouseDown(with event: NSEvent) {
        if closable && event.buttonNumber == 2 { onClose?(index) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(index)
    }

    @objc private func closeClicked(_ sender: Any?) {
        onClose?(index)
    }
}
