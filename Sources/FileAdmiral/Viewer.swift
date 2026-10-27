import AppKit
import UniformTypeIdentifiers

/// Lister: the F3 file viewer with text, hex and image modes.
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    private static var openViewers: [ViewerWindowController] = []

    enum Mode: Int { case text = 0, hex = 1, image = 2 }

    static let encodings: [(String, String.Encoding)] = {
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        return [
            ("UTF-8", .utf8),
            ("UTF-16", .utf16),
            ("Windows-1251 (Cyrillic)", .windowsCP1251),
            ("KOI8-R", cf(.KOI8_R)),
            ("DOS 866", cf(.dosRussian)),
            ("Windows-1252 (Western)", .windowsCP1252),
            ("ISO Latin-1", .isoLatin1),
            ("Mac Roman", .macOSRoman),
        ]
    }()

    private static let textLimit = 16 << 20
    private static let hexLimit = 4 << 20

    private let url: URL?
    private var data = Data()
    private var plainText: String?
    private var image: NSImage?
    private var mode: Mode = .text
    private var encodingIndex = 0
    private var viewerPlugins: [Plugin] = []
    private var readError: String?

    private let modeControl = NSSegmentedControl(labels: ["Text", "Hex", "Image"], trackingMode: .selectOne, target: nil, action: nil)
    private let encodingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let wrapCheck = NSButton(checkboxWithTitle: "Wrap lines", target: nil, action: nil)
    private let infoLabel = NSTextField(labelWithString: "")
    private let textScroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { textScroll.documentView as! NSTextView }
    private let imageView = NSImageView()
    private var keyMonitor: Any?

    static func show(url: URL) {
        let v = ViewerWindowController(url: url, text: nil, title: nil)
        openViewers.append(v)
        v.showWindow(nil)
        v.window?.makeKeyAndOrderFront(nil)
    }

    static func show(text: String, title: String) {
        let v = ViewerWindowController(url: nil, text: text, title: title)
        openViewers.append(v)
        v.showWindow(nil)
        v.window?.makeKeyAndOrderFront(nil)
    }

    private init(url: URL?, text: String?, title: String?) {
        self.url = url
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = title ?? "Lister - [\(url?.path ?? "")]"
        super.init(window: w)
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("Lister")
        buildUI()

        if let text {
            plainText = text
            modeControl.isEnabled = false
            encodingPopup.isEnabled = false
            setMode(.text)
        } else if let url {
            // Only regular files are read: a FIFO or device would block forever (or never end).
            var st = stat()
            if stat(url.path, &st) == 0 && (st.st_mode & S_IFMT) != S_IFREG {
                readError = "Not a regular file (pipe, socket or device)."
            } else {
                do {
                    data = try Data(contentsOf: url, options: .alwaysMapped)
                } catch {
                    readError = error.localizedDescription
                }
            }
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                image = NSImage(contentsOf: url)
            }
            modeControl.setEnabled(image != nil, forSegment: Mode.image.rawValue)
            viewerPlugins = PluginManager.shared.viewerPlugins(for: url)
            if !viewerPlugins.isEmpty {
                modeControl.segmentCount = 3 + viewerPlugins.count
                for (i, p) in viewerPlugins.enumerated() {
                    modeControl.setLabel(p.name, forSegment: 3 + i)
                    modeControl.setToolTip("Plugin: \(p.description)", forSegment: 3 + i)
                }
            }
            encodingIndex = Settings.listerEncoding >= 0 && Settings.listerEncoding < Self.encodings.count
                ? Settings.listerEncoding : detectEncoding()
            encodingPopup.selectItem(at: encodingIndex)
            if let readError {
                plainText = "Cannot read \(url.path)\n\n\(readError)"
                modeControl.isEnabled = false
                setMode(.text)
            } else {
                // UTF-16 text contains zero bytes but is not binary.
                setMode(image != nil ? .image : (encodingIndex != 1 && looksBinary() ? .hex : .text))
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            // Typing in the Find bar's search field (or any other text field) is not a Lister shortcut.
            if let responder = self.window?.firstResponder as? NSView, responder !== self.textView,
               responder is NSText || responder is NSTextField {
                return e
            }
            let mods = e.modifierFlags.intersection([.command, .control, .option])
            if e.keyCode == 53, self.textScroll.isFindBarVisible {
                // First Esc closes the Find bar, the next one the window.
                self.textScroll.isFindBarVisible = false
                self.window?.makeFirstResponder(self.textView)
                return nil
            }
            if e.keyCode == 53 || e.keyCode == 99 { // Esc, F3
                self.close()
                return nil
            }
            if mods.isEmpty, self.plainText == nil, let ch = e.charactersIgnoringModifiers {
                switch ch {
                case "1": self.setMode(.text); return nil
                case "3": self.setMode(.hex); return nil
                case "4" where self.image != nil: self.setMode(.image); return nil
                case "w": self.wrapCheck.state = self.wrapCheck.state == .on ? .off : .on; self.applyWrap(); return nil
                default: break
                }
            }
            return e
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.controlSize = .small
        for (i, tip) in ["Text (1)", "Hex (3)", "Image (4)"].enumerated() { modeControl.setToolTip(tip, forSegment: i) }

        encodingPopup.controlSize = .small
        encodingPopup.font = Theme.smallFont
        encodingPopup.addItems(withTitles: Self.encodings.map(\.0))
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged(_:))

        wrapCheck.target = self
        wrapCheck.action = #selector(wrapChanged(_:))
        wrapCheck.controlSize = .small
        wrapCheck.font = Theme.smallFont
        wrapCheck.state = .on

        infoLabel.font = Theme.smallFont
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingHead
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [modeControl, encodingPopup, wrapCheck, infoLabel])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = Theme.monoFont
        // Lay out big files lazily instead of measuring every line before the first one appears.
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textScroll.hasHorizontalScroller = true

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor

        for v in [bar, textScroll, imageView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
            textScroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            textScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            imageView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func looksBinary() -> Bool {
        let sample = data.prefix(8192)
        return sample.contains(0)
    }

    /// Decodes without ever failing: bytes that are undefined in the encoding become U+FFFD,
    /// instead of the whole text falling back to (garbled) UTF-8.
    static func decode(_ data: Data, encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8:
            return String(decoding: data, as: UTF8.self)
        case .utf16:
            let even = data.count % 2 == 0 ? data : data.dropLast()
            return String(data: even, encoding: .utf16) ?? String(decoding: data, as: UTF8.self)
        default:
            // Single-byte encodings: decode via a 256-entry table built once per encoding.
            let table = singleByteTable(encoding)
            var scalars = String.UnicodeScalarView()
            scalars.reserveCapacity(data.count)
            for b in data { scalars.append(table[Int(b)]) }
            return String(scalars)
        }
    }

    private static var tables: [UInt: [Unicode.Scalar]] = [:]

    private static func singleByteTable(_ encoding: String.Encoding) -> [Unicode.Scalar] {
        if let t = tables[encoding.rawValue] { return t }
        let t: [Unicode.Scalar] = (0..<256).map { b in
            String(data: Data([UInt8(b)]), encoding: encoding)?.unicodeScalars.first ?? "\u{FFFD}"
        }
        tables[encoding.rawValue] = t
        return t
    }

    private func detectEncoding() -> Int {
        let sample = data.prefix(65536)
        if sample.starts(with: [0xFF, 0xFE]) || sample.starts(with: [0xFE, 0xFF]) { return 1 }
        let decoded = String(decoding: sample, as: UTF8.self)
        let bad = decoded.unicodeScalars.reduce(0) { $0 + ($1.value == 0xFFFD ? 1 : 0) }
        return bad <= 2 ? 0 : Settings.fallbackEncoding
    }

    private func setMode(_ m: Mode) {
        mode = m
        modeControl.selectedSegment = m.rawValue
        encodingPopup.isHidden = m != .text || plainText != nil
        wrapCheck.isHidden = m == .image
        textScroll.isHidden = m == .image
        imageView.isHidden = m != .image
        let size = url != nil ? "\(Fmt.int(Int64(data.count))) bytes" : ""
        switch m {
        case .text:
            let s: String
            if let plainText {
                s = plainText
            } else {
                let slice = data.prefix(Self.textLimit)
                s = Self.decode(slice, encoding: Self.encodings[encodingIndex].1)
            }
            textView.string = s
            applyWrap()
            infoLabel.stringValue = size + (data.count > Self.textLimit ? "  (first \(Fmt.bytes(Int64(Self.textLimit))) shown)" : "")
        case .hex:
            textView.string = Self.hexDump(data, limit: Self.hexLimit)
            applyWrap() // hex is never wrapped; the checkbox keeps the user's choice for text mode
            infoLabel.stringValue = size + (data.count > Self.hexLimit ? "  (first \(Fmt.bytes(Int64(Self.hexLimit))) shown)" : "")
        case .image:
            imageView.image = image
            if let image, let rep = image.representations.first {
                infoLabel.stringValue = "\(rep.pixelsWide) × \(rep.pixelsHigh) px   " + size
            }
        }
        textView.scroll(.zero)
        window?.makeFirstResponder(m == .image ? imageView : textView)
    }

    private func applyWrap() {
        let wrap = wrapCheck.state == .on && mode == .text
        guard let container = textView.textContainer else { return }
        if wrap {
            textScroll.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: textScroll.contentSize.width, height: .greatestFiniteMagnitude)
            textView.frame.size.width = textScroll.contentSize.width
        } else {
            textScroll.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }

    static func hexDump(_ data: Data, limit: Int) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var out = [UInt8]()
        let bytes = data.prefix(limit)
        out.reserveCapacity(bytes.count / 16 * 78 + 80)
        bytes.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < p.count {
                let lineLen = min(16, p.count - offset)
                for shift in stride(from: 28, through: 0, by: -4) {
                    out.append(digits[(offset >> shift) & 0xF])
                }
                out.append(UInt8(ascii: ":"))
                out.append(UInt8(ascii: " "))
                for i in 0..<16 {
                    if i == 8 { out.append(UInt8(ascii: " ")) }
                    if i < lineLen {
                        let b = p[offset + i]
                        out.append(digits[Int(b >> 4)])
                        out.append(digits[Int(b & 0xF)])
                    } else {
                        out.append(UInt8(ascii: " "))
                        out.append(UInt8(ascii: " "))
                    }
                    out.append(UInt8(ascii: " "))
                }
                out.append(UInt8(ascii: " "))
                for i in 0..<lineLen {
                    let b = p[offset + i]
                    out.append(b >= 0x20 && b < 0x7F ? b : UInt8(ascii: "."))
                }
                out.append(UInt8(ascii: "\n"))
                offset += 16
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment >= 3 {
            showPlugin(sender.selectedSegment - 3)
        } else {
            setMode(Mode(rawValue: sender.selectedSegment) ?? .text)
        }
    }

    /// Shows the output of a viewer plugin for the current file.
    private func showPlugin(_ index: Int) {
        guard let url, index < viewerPlugins.count else { return }
        let plugin = viewerPlugins[index]
        mode = .text
        modeControl.selectedSegment = 3 + index
        encodingPopup.isHidden = true
        wrapCheck.isHidden = false
        textScroll.isHidden = false
        imageView.isHidden = true
        textView.string = "Running \(plugin.name)…"
        infoLabel.stringValue = "Plugin: \(plugin.name)"
        PluginManager.shared.render(plugin, file: url) { [weak self] text in
            guard let self, self.modeControl.selectedSegment == 3 + index else { return }
            self.textView.string = text
            self.applyWrap()
            self.textView.scroll(.zero)
        }
        window?.makeFirstResponder(textView)
    }

    @objc private func encodingChanged(_ sender: NSPopUpButton) {
        encodingIndex = max(0, sender.indexOfSelectedItem)
        setMode(.text)
    }

    @objc private func wrapChanged(_ sender: Any?) {
        applyWrap()
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        DispatchQueue.main.async {
            Self.openViewers.removeAll { $0 === self }
        }
    }
}
