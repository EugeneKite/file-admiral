import AppKit

extension Notification.Name {
    /// Posted when a setting that affects panels or layout changes.
    static let settingsChanged = Notification.Name("FileAdmiralSettingsChanged")
}

/// User preferences, stored in UserDefaults. Changing a value posts `.settingsChanged`.
enum Settings {
    enum SizeFormat: String, CaseIterable {
        case bytes, kilobytes, dynamic
        var title: String {
            switch self {
            case .bytes: return "Bytes (1,234,567)"
            case .kilobytes: return "Kilobytes (1,206 k)"
            case .dynamic: return "Dynamic (1.2 MB)"
            }
        }
    }

    enum DateStyle: String, CaseIterable {
        case european, iso, us, system
        var title: String {
            switch self {
            case .european: return "25.10.2026 21:59"
            case .iso: return "2026-10-25 21:59"
            case .us: return "10/25/2026 9:59 PM"
            case .system: return "System format"
            }
        }
    }

    enum TypingAction: String, CaseIterable {
        case quickSearch, commandLine
        var title: String {
            switch self {
            case .quickSearch: return "Start quick search (jump to file)"
            case .commandLine: return "Type into the command line (classic TC)"
            }
        }
    }

    enum ThumbnailSize: String, CaseIterable {
        case small, medium, large, huge
        var points: CGFloat {
            switch self {
            case .small: return 80
            case .medium: return 128
            case .large: return 192
            case .huge: return 288
            }
        }
        var title: String { rawValue.capitalized }
    }

    enum TerminalApp: String, CaseIterable {
        case terminal = "com.apple.Terminal", iterm = "com.googlecode.iterm2", warp = "dev.warp.Warp-Stable",
             ghostty = "com.mitchellh.ghostty", kitty = "net.kovidgoyal.kitty"
        var title: String {
            switch self {
            case .terminal: return "Terminal"
            case .iterm: return "iTerm2"
            case .warp: return "Warp"
            case .ghostty: return "Ghostty"
            case .kitty: return "kitty"
            }
        }
    }

    private static let d = UserDefaults.standard

    private static func bool(_ key: String, _ def: Bool) -> Bool {
        d.object(forKey: key) as? Bool ?? def
    }

    private static func set(_ value: Any?, _ key: String) {
        d.set(value, forKey: key)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    // General
    static var confirmDelete: Bool {
        get { bool("confirmDelete", true) }
        set { set(newValue, "confirmDelete") }
    }
    static var deleteToTrash: Bool {
        get { bool("deleteToTrash", true) }
        set { set(newValue, "deleteToTrash") }
    }
    static var typingAction: TypingAction {
        get { TypingAction(rawValue: d.string(forKey: "typingAction") ?? "") ?? .quickSearch }
        set { set(newValue.rawValue, "typingAction") }
    }
    static var restoreTabs: Bool {
        get { bool("restoreTabs", true) }
        set { set(newValue, "restoreTabs") }
    }
    static var newTabAtEnd: Bool {
        get { bool("newTabAtEnd", false) }
        set { set(newValue, "newTabAtEnd") }
    }

    // Display
    static var showToolbar: Bool {
        get { bool("showToolbar", true) }
        set { set(newValue, "showToolbar") }
    }
    static var showCommandLine: Bool {
        get { bool("showCommandLine", true) }
        set { set(newValue, "showCommandLine") }
    }
    static var showFunctionKeys: Bool {
        get { bool("showFunctionKeys", true) }
        set { set(newValue, "showFunctionKeys") }
    }
    static var sizeFormat: SizeFormat {
        get { SizeFormat(rawValue: d.string(forKey: "sizeFormat") ?? "") ?? .bytes }
        set { set(newValue.rawValue, "sizeFormat") }
    }
    static var dateStyle: DateStyle {
        get { DateStyle(rawValue: d.string(forKey: "dateStyle") ?? "") ?? .european }
        set { set(newValue.rawValue, "dateStyle") }
    }
    static var folderBrackets: Bool {
        get { bool("folderBrackets", true) }
        set { set(newValue, "folderBrackets") }
    }
    static var showIcons: Bool {
        get { bool("showIcons", true) }
        set { set(newValue, "showIcons") }
    }
    static var foldersFirst: Bool {
        get { bool("foldersFirst", true) }
        set { set(newValue, "foldersFirst") }
    }

    static var thumbnailSize: ThumbnailSize {
        get { ThumbnailSize(rawValue: d.string(forKey: "thumbnailSize") ?? "") ?? .medium }
        set { set(newValue.rawValue, "thumbnailSize") }
    }

    // Tools
    static var terminalApp: TerminalApp {
        get { TerminalApp(rawValue: d.string(forKey: "terminalApp") ?? "") ?? .terminal }
        set { set(newValue.rawValue, "terminalApp") }
    }
    /// Index into ViewerWindowController.encodings, or -1 for automatic detection.
    static var listerEncoding: Int {
        get { d.object(forKey: "listerEncoding") as? Int ?? -1 }
        set { set(newValue, "listerEncoding") }
    }
    /// Encoding (index into ViewerWindowController.encodings) assumed for text that is not valid UTF-8/UTF-16.
    static var fallbackEncoding: Int {
        get {
            let v = d.object(forKey: "fallbackEncoding") as? Int ?? 5 // Windows-1252
            return (2..<ViewerWindowController.encodings.count).contains(v) ? v : 5
        }
        set { set(newValue, "fallbackEncoding") }
    }
}

/// Configuration → Settings… (⌘,).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    private weak var controller: MainWindowController?
    private let pluginList = NSTextField(wrappingLabelWithString: "")
    private let editorLabel = NSTextField(labelWithString: "")

    static func show(controller: MainWindowController) {
        let s = shared ?? SettingsWindowController(controller: controller)
        shared = s
        s.refreshDynamic()
        s.showWindow(nil)
        s.window?.makeKeyAndOrderFront(nil)
    }

    private init(controller: MainWindowController) {
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        buildUI()
        w.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: Control factories (each control writes its setting directly)

    private final class Binding: NSObject {
        let apply: (Any) -> Void
        init(_ apply: @escaping (Any) -> Void) { self.apply = apply }
        @objc func fire(_ sender: Any) { apply(sender) }
    }

    private var bindings: [Binding] = []

    private func check(_ title: String, _ value: Bool, _ apply: @escaping (Bool) -> Void) -> NSButton {
        let b = Binding { apply(($0 as? NSButton)?.state == .on) }
        bindings.append(b)
        let c = NSButton(checkboxWithTitle: title, target: b, action: #selector(Binding.fire(_:)))
        c.state = value ? .on : .off
        return c
    }

    private func popup(_ titles: [String], selected: Int, _ apply: @escaping (Int) -> Void) -> NSPopUpButton {
        let b = Binding { apply(($0 as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
        bindings.append(b)
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        p.selectItem(at: max(selected, 0))
        p.target = b
        p.action = #selector(Binding.fire(_:))
        return p
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = Binding { _ in action() }
        bindings.append(b)
        return NSButton(title: title, target: b, action: #selector(Binding.fire(_:)))
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = Theme.smallFont
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 420
        return l
    }

    private func page(_ rows: [[NSView]]) -> NSView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        return container
    }

    private var empty: NSView { NSGridCell.emptyContentView }

    // MARK: Pages

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        for (title, view) in [("General", generalPage()), ("Display", displayPage()), ("Tools", toolsPage()),
                              ("Plugins", pluginsPage())] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = view
            tabs.addTabViewItem(item)
        }
    }

    private func generalPage() -> NSView {
        page([
            [label("Delete (F8):"), check("Ask for confirmation", Settings.confirmDelete) { Settings.confirmDelete = $0 }],
            [empty, check("Move to Trash (Shift+F8 always deletes permanently)", Settings.deleteToTrash) {
                Settings.deleteToTrash = $0
            }],
            [label("Typing letters:"), popup(Settings.TypingAction.allCases.map(\.title),
                                             selected: Settings.TypingAction.allCases.firstIndex(of: Settings.typingAction) ?? 0) {
                Settings.typingAction = Settings.TypingAction.allCases[$0]
            }],
            [empty, note("In command-line mode, quick search is still available with ⌥ + letter.")],
            [label("Tabs:"), check("Restore tabs and folders at startup", Settings.restoreTabs) { Settings.restoreTabs = $0 }],
            [empty, check("Open new tabs at the end (instead of next to the current tab)", Settings.newTabAtEnd) {
                Settings.newTabAtEnd = $0
            }],
            [label("Permissions:"), button("Open Permissions…") { PermissionsWindowController.show() }],
        ])
    }

    private func displayPage() -> NSView {
        let schemes = [Theme.automaticName] + ColorScheme.all.map(\.name)
        let fontStepper = NSStepper()
        let fontValue = NSTextField(labelWithString: "\(Int(Theme.fontSize)) pt")
        let stepBinding = Binding { sender in
            guard let s = sender as? NSStepper else { return }
            Theme.fontSize = CGFloat(s.integerValue)
            fontValue.stringValue = "\(Int(Theme.fontSize)) pt"
        }
        bindings.append(stepBinding)
        fontStepper.minValue = 9
        fontStepper.maxValue = 24
        fontStepper.integerValue = Int(Theme.fontSize)
        fontStepper.target = stepBinding
        fontStepper.action = #selector(Binding.fire(_:))
        let fontRow = NSStackView(views: [fontValue, fontStepper])
        fontRow.spacing = 6
        return page([
            [label("Color theme:"), popup(schemes, selected: schemes.firstIndex(of: Theme.schemeName) ?? 1) {
                Theme.schemeName = schemes[$0]
            }],
            [label("Panel font size:"), fontRow],
            [label("Show:"), check("Toolbar", Settings.showToolbar) { Settings.showToolbar = $0 }],
            [empty, check("Command line", Settings.showCommandLine) { Settings.showCommandLine = $0 }],
            [empty, check("Function key buttons (F3–F8)", Settings.showFunctionKeys) { Settings.showFunctionKeys = $0 }],
            [empty, check("Hidden files", controller?.showHidden ?? false) { [weak self] on in
                if self?.controller?.showHidden != on { self?.controller?.toggleHidden(nil) }
            }],
            [empty, check("File icons", Settings.showIcons) { Settings.showIcons = $0 }],
            [label("Folders:"), check("Show folder names in [brackets]", Settings.folderBrackets) { Settings.folderBrackets = $0 }],
            [empty, check("Always list folders before files", Settings.foldersFirst) { Settings.foldersFirst = $0 }],
            [label("Thumbnails:"), popup(Settings.ThumbnailSize.allCases.map(\.title),
                                         selected: Settings.ThumbnailSize.allCases.firstIndex(of: Settings.thumbnailSize) ?? 1) {
                Settings.thumbnailSize = Settings.ThumbnailSize.allCases[$0]
            }],
            [label("File sizes:"), popup(Settings.SizeFormat.allCases.map(\.title),
                                         selected: Settings.SizeFormat.allCases.firstIndex(of: Settings.sizeFormat) ?? 0) {
                Settings.sizeFormat = Settings.SizeFormat.allCases[$0]
            }],
            [label("Dates:"), popup(Settings.DateStyle.allCases.map(\.title),
                                    selected: Settings.DateStyle.allCases.firstIndex(of: Settings.dateStyle) ?? 0) {
                Settings.dateStyle = Settings.DateStyle.allCases[$0]
            }],
        ])
    }

    private func toolsPage() -> NSView {
        let encodings = ["Automatic"] + ViewerWindowController.encodings.map(\.0)
        let editorRow = NSStackView(views: [editorLabel, button("Choose…") { [weak self] in
            self?.controller?.chooseEditor(nil)
            self?.refreshDynamic()
        }, button("Use default") { [weak self] in
            UserDefaults.standard.removeObject(forKey: "editorApp")
            self?.refreshDynamic()
        }])
        editorRow.spacing = 8
        return page([
            [label("Editor (F4):"), editorRow],
            [label("Terminal app:"), popup(Settings.TerminalApp.allCases.map(\.title),
                                           selected: Settings.TerminalApp.allCases.firstIndex(of: Settings.terminalApp) ?? 0) {
                Settings.terminalApp = Settings.TerminalApp.allCases[$0]
            }],
            [label("Lister encoding:"), popup(encodings, selected: Settings.listerEncoding + 1) {
                Settings.listerEncoding = $0 - 1
            }],
            [label("Non-UTF-8 text:"), popup(Array(ViewerWindowController.encodings.map(\.0).dropFirst(2)),
                                             selected: Settings.fallbackEncoding - 2) {
                Settings.fallbackEncoding = $0 + 2
            }],
            [empty, note("Automatic detects UTF-8 and UTF-16; anything else is shown in the \"Non-UTF-8 text\" encoding "
                         + "(also used by Compare by Content). The encoding can still be changed in the Lister window.")],
        ])
    }

    private func pluginsPage() -> NSView {
        pluginList.preferredMaxLayoutWidth = 520
        pluginList.font = Theme.smallFont
        let buttons = NSStackView(views: [
            button("Open Plugins Folder") { [weak self] in self?.controller?.openPluginsFolder(nil) },
            button("Reload") { [weak self] in
                self?.controller?.reloadPlugins()
                self?.refreshDynamic()
            },
            button("Install Samples") { [weak self] in
                self?.controller?.installSamplePlugins(nil)
                self?.refreshDynamic()
            },
            button("How to Write a Plugin…") { [weak self] in self?.controller?.showPluginHelp(nil) },
        ])
        buttons.spacing = 8
        let stack = NSStackView(views: [buttons, pluginList])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        return container
    }

    private func refreshDynamic() {
        if let id = UserDefaults.standard.string(forKey: "editorApp"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            editorLabel.stringValue = FileManager.default.displayName(atPath: url.path)
        } else {
            editorLabel.stringValue = "Default text editor"
        }
        let pm = PluginManager.shared
        if pm.plugins.isEmpty {
            pluginList.stringValue = "No plugins installed. Plugins live in \(pm.folder.abbreviatedPath)."
        } else {
            pluginList.stringValue = pm.plugins.map { p in
                let kind = p.kind == .viewer ? "Lister" : "Command"
                let extra = [p.shortcutText.map { "shortcut \($0)" }, p.toolbar ? "toolbar" : nil].compactMap { $0 }
                return "• \(p.name)  [\(kind)\(extra.isEmpty ? "" : ", " + extra.joined(separator: ", "))]"
                    + (p.description.isEmpty ? "" : "\n   \(p.description)")
            }.joined(separator: "\n")
        }
    }
}
