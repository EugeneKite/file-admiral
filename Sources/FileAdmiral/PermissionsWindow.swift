import AppKit
import Darwin

/// Explains and requests macOS privacy permissions (TCC) in one place.
///
/// Apps cannot grant themselves access, so this window does the next best thing:
/// detects Full Disk Access live, opens the right System Settings page, and triggers
/// all per-folder prompts (Desktop, Documents, Downloads, …) in one go.
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: PermissionsWindowController?

    private struct Folder {
        let title: String
        let url: URL
    }

    private enum State { case unknown, granted, denied }

    private let folders: [Folder] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            Folder(title: "Desktop", url: home.appendingPathComponent("Desktop")),
            Folder(title: "Documents", url: home.appendingPathComponent("Documents")),
            Folder(title: "Downloads", url: home.appendingPathComponent("Downloads")),
            Folder(title: "iCloud Drive", url: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")),
        ].filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }()

    private var folderStates: [State] = []
    private var folderIcons: [NSImageView] = []
    private let fdaIcon = NSImageView()
    private let fdaStatus = NSTextField(labelWithString: "")
    private let relaunchButton = NSButton(title: "Relaunch FileAdmiral", target: nil, action: nil)
    private var timer: Timer?
    /// Full Disk Access state when the app started; recorded by the app delegate at launch.
    static var fdaAtLaunch = false
    private var fdaAtLaunch: Bool { Self.fdaAtLaunch }

    /// Full Disk Access is the only way to read the system TCC database.
    static var hasFullDiskAccess: Bool {
        let fd = Darwin.open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { Darwin.close(fd); return true }
        return false
    }

    static func show() {
        let c = shared ?? PermissionsWindowController()
        shared = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    /// Shows the window on first launch when Full Disk Access is missing.
    static func showOnFirstLaunchIfNeeded() {
        let key = "permissionsOnboardingShown"
        guard !UserDefaults.standard.bool(forKey: key), !hasFullDiskAccess else { return }
        UserDefaults.standard.set(true, forKey: key)
        show()
    }

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Permissions"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        let saved = UserDefaults.standard.dictionary(forKey: "folderAccess") as? [String: Bool] ?? [:]
        folderStates = folders.map { f in saved[f.url.path].map { $0 ? .granted : .denied } ?? .unknown }
        buildUI()
        refresh()
        w.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func symbol(_ state: State) -> NSImage? {
        let (name, color): (String, NSColor) = {
            switch state {
            case .granted: return ("checkmark.circle.fill", .systemGreen)
            case .denied: return ("xmark.circle.fill", .systemRed)
            case .unknown: return ("questionmark.circle", .systemGray)
            }
        }()
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private func wrapping(_ s: String, small: Bool = true) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = small ? Theme.smallFont : Theme.font
        t.textColor = small ? .secondaryLabelColor : .labelColor
        t.preferredMaxLayoutWidth = 500
        return t
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Full Disk Access section
        let fdaTitle = NSTextField(labelWithString: "Full Disk Access (recommended)")
        fdaTitle.font = Theme.boldFont
        let fdaHeader = NSStackView(views: [fdaIcon, fdaTitle, fdaStatus])
        fdaHeader.spacing = 6
        let fdaText = wrapping("Gives FileAdmiral access to every folder at once (Desktop, Documents, Mail, Safari data, "
            + "external drives…) with no further prompts — the usual setting for a file manager. "
            + "Click the button, then switch FileAdmiral on in the list (or drag it in with “+”).")
        let openFDA = NSButton(title: "Open Full Disk Access Settings…", target: self, action: #selector(openFullDiskAccess(_:)))
        openFDA.bezelStyle = .rounded
        openFDA.keyEquivalent = "\r"
        let reveal = NSButton(title: "Show App in Finder", target: self, action: #selector(revealApp(_:)))
        reveal.bezelStyle = .rounded
        reveal.toolTip = "Drag FileAdmiral from Finder into the Full Disk Access list"
        relaunchButton.target = self
        relaunchButton.action = #selector(relaunch(_:))
        relaunchButton.bezelStyle = .rounded
        relaunchButton.isHidden = true
        let fdaButtons = NSStackView(views: [openFDA, reveal, relaunchButton])
        fdaButtons.spacing = 8

        // Per-folder section
        let folderTitle = NSTextField(labelWithString: "Or allow individual folders")
        folderTitle.font = Theme.boldFont
        let folderText = wrapping("macOS asks once per protected folder. This requests all of them now, so you can answer "
            + "the prompts in one go instead of while you work.")
        var rows: [NSView] = []
        for f in folders {
            let icon = NSImageView()
            folderIcons.append(icon)
            let label = NSTextField(labelWithString: f.title)
            let path = NSTextField(labelWithString: f.url.abbreviatedPath)
            path.font = Theme.smallFont
            path.textColor = .secondaryLabelColor
            let row = NSStackView(views: [icon, label, path])
            row.spacing = 6
            rows.append(row)
        }
        let requestFolders = NSButton(title: "Request Folder Access", target: self, action: #selector(requestFolders(_:)))
        requestFolders.bezelStyle = .rounded
        let privacySettings = NSButton(title: "Files & Folders Settings…", target: self, action: #selector(openFilesAndFolders(_:)))
        privacySettings.bezelStyle = .rounded
        let folderButtons = NSStackView(views: [requestFolders, privacySettings])
        folderButtons.spacing = 8

        let note = wrapping("Removable and network volumes prompt the first time you open them. "
            + "Permissions can be changed any time in System Settings → Privacy & Security.")

        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow(_:)))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"
        let doneRow = NSStackView()
        doneRow.addView(done, in: .trailing)

        let sep = NSBox()
        sep.boxType = .separator
        let stack = NSStackView(views: [fdaHeader, fdaText, fdaButtons, sep, folderTitle, folderText] + rows
            + [folderButtons, note, doneRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: fdaButtons)
        stack.setCustomSpacing(16, after: sep)
        stack.setCustomSpacing(14, after: folderButtons)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            doneRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            content.widthAnchor.constraint(equalToConstant: 560),
        ])
    }

    private func refresh() {
        let fda = Self.hasFullDiskAccess
        fdaIcon.image = symbol(fda ? .granted : .unknown)
        fdaStatus.stringValue = fda ? "— granted" : "— not granted"
        fdaStatus.textColor = fda ? .systemGreen : .secondaryLabelColor
        // A newly granted Full Disk Access only fully applies after a restart of the app.
        relaunchButton.isHidden = !(fda && !fdaAtLaunch)
        for (i, icon) in folderIcons.enumerated() {
            icon.image = symbol(fda ? .granted : folderStates[i])
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        recheckFolders()
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Polling only matters while the window is in front (it reads the TCC database every 1.5 s).
    func windowDidResignKey(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    /// Re-checks folders whose permission was already decided (granted or denied): accessing them
    /// again shows no prompt, and picks up changes made in System Settings meanwhile.
    private func recheckFolders() {
        let urls = folders.map(\.url)
        let states = folderStates
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results: [State] = zip(urls, states).map { url, state in
                guard state != .unknown else { return .unknown }
                return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil ? .granted : .denied
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.folderStates = results
                self.refresh()
            }
        }
    }

    @objc private func openFullDiskAccess(_ sender: Any?) {
        // Adding the app to the list happens in System Settings; listing a folder first makes
        // macOS register FileAdmiral there so the user only needs to flip the switch.
        _ = try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Safari")
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    @objc private func openFilesAndFolders(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }

    @objc private func revealApp(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func requestFolders(_ sender: NSButton) {
        sender.isEnabled = false
        let urls = folders.map(\.url)
        // Each access shows its own system prompt and blocks until it is answered,
        // so walk the folders sequentially off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [Bool] = []
            for u in urls {
                results.append((try? FileManager.default.contentsOfDirectory(atPath: u.path)) != nil)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                sender.isEnabled = true
                var saved = UserDefaults.standard.dictionary(forKey: "folderAccess") as? [String: Bool] ?? [:]
                for (i, ok) in results.enumerated() {
                    self.folderStates[i] = ok ? .granted : .denied
                    saved[urls[i].path] = ok
                }
                UserDefaults.standard.set(saved, forKey: "folderAccess")
                self.refresh()
            }
        }
    }

    @objc private func relaunch(_ sender: Any?) {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait until this process has really exited, otherwise `open` would just activate it.
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path, "\(pid)"]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.close()
    }
}
