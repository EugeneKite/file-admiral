import AppKit
import Security

/// A saved FTP/SFTP connection. Passwords are kept in the macOS Keychain, not in preferences.
struct Connection: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case sftp, ftp, ftps
        var title: String {
            switch self {
            case .sftp: return "SFTP (SSH)"
            case .ftp: return "FTP"
            case .ftps: return "FTPS (FTP over TLS)"
            }
        }
        var defaultPort: Int { self == .sftp ? 22 : 21 }
    }

    var id = UUID().uuidString
    var name: String
    var kind: Kind
    var host: String
    var port: Int
    var user: String
    var keyFile: String = ""
    var path: String = ""
    var allowInvalidCertificate = false

    var label: String { name.isEmpty ? "\(user.isEmpty ? "" : user + "@")\(host)" : name }
}

enum ConnectionStore {
    private static let key = "connections"

    static var all: [Connection] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([Connection].self, from: data) else { return [] }
            return list
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
            NotificationCenter.default.post(name: .connectionsChanged, object: nil)
        }
    }

    // MARK: Keychain

    private static func query(_ c: Connection) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "FileAdmiral connection",
         kSecAttrAccount as String: c.id]
    }

    static func password(for c: Connection) -> String? {
        var q = query(c)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?, for c: Connection) {
        SecItemDelete(query(c) as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var q = query(c)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "FileAdmiral: \(c.label)"
        SecItemAdd(q as CFDictionary, nil)
    }

    static func remove(_ c: Connection) {
        setPassword(nil, for: c)
        all = all.filter { $0.id != c.id }
    }
}

extension Notification.Name {
    static let connectionsChanged = Notification.Name("FileAdmiralConnectionsChanged")
}

/// Net → Connect (⌘K): saved connections plus quick connect.
final class ConnectionsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var shared: ConnectionsWindowController?
    private weak var controller: MainWindowController?

    private var connections: [Connection] = ConnectionStore.all
    private let table = NSTableView()
    private let nameField = NSTextField()
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let savePassword = NSButton(checkboxWithTitle: "Remember password in Keychain", target: nil, action: nil)
    private let keyField = NSTextField()
    private let keyButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let pathField = NSTextField()
    private let insecureCheck = NSButton(checkboxWithTitle: "Accept invalid or self-signed certificates", target: nil, action: nil)
    private let newTabCheck = NSButton(checkboxWithTitle: "Open in a new tab", target: nil, action: nil)
    private var editingID: String?

    static func show(controller: MainWindowController) {
        let c = shared ?? ConnectionsWindowController(controller: controller)
        shared = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private init(controller: MainWindowController) {
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Connect to Server (FTP / SFTP)"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        buildUI()
        w.center()
        if !connections.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            load(connections[0])
        } else {
            newConnection(nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let col = NSTableColumn(identifier: .init("name"))
        col.title = "Saved connections"
        col.width = 200
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.target = self
        table.doubleAction = #selector(connect(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let newButton = NSButton(title: "New", target: self, action: #selector(newConnection(_:)))
        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteConnection(_:)))
        let listButtons = NSStackView(views: [newButton, deleteButton])

        kindPopup.addItems(withTitles: Connection.Kind.allCases.map(\.title))
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged(_:))
        portField.placeholderString = "22"
        userField.placeholderString = "user name (empty = anonymous FTP)"
        passwordField.placeholderString = "password or key passphrase"
        keyField.placeholderString = "~/.ssh/id_ed25519 (optional; default keys and ssh-agent are used too)"
        pathField.placeholderString = "remote folder to open (optional)"
        nameField.placeholderString = "name shown in the list (optional)"
        keyButton.target = self
        keyButton.action = #selector(chooseKey(_:))
        savePassword.state = .on
        newTabCheck.state = .on
        let keyRow = NSStackView(views: [keyField, keyButton])
        keyRow.spacing = 6
        let hostRow = NSStackView(views: [hostField, label("Port:"), portField])
        hostRow.spacing = 6
        portField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let grid = NSGridView(views: [
            [label("Protocol:"), kindPopup],
            [label("Host:"), hostRow],
            [label("User:"), userField],
            [label("Password:"), passwordField],
            [NSGridCell.emptyContentView, savePassword],
            [label("Private key:"), keyRow],
            [label("Remote folder:"), pathField],
            [label("Name:"), nameField],
            [NSGridCell.emptyContentView, insecureCheck],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for f in [hostField, userField, passwordField, keyField, pathField, nameField] as [NSTextField] {
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }

        let note = NSTextField(wrappingLabelWithString:
            "SFTP uses the system OpenSSH, including ~/.ssh/config, ssh-agent and your default keys. New host keys are accepted on first connect and checked afterwards.")
        note.font = Theme.smallFont
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 480

        let save = NSButton(title: "Save", target: self, action: #selector(saveConnection(_:)))
        let connect = NSButton(title: "Connect", target: self, action: #selector(connect(_:)))
        connect.keyEquivalent = "\r"
        let cancel = NSButton(title: "Close", target: self, action: #selector(closeWindow(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [newTabCheck, NSView(), cancel, save, connect])
        buttons.spacing = 8

        for v in [scroll, listButtons, grid, note, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.widthAnchor.constraint(equalToConstant: 200),
            scroll.bottomAnchor.constraint(equalTo: listButtons.topAnchor, constant: -8),
            listButtons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            listButtons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            note.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            buttons.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private var selectedKind: Connection.Kind { Connection.Kind.allCases[max(kindPopup.indexOfSelectedItem, 0)] }

    @objc private func kindChanged(_ sender: Any?) {
        let kind = selectedKind
        portField.placeholderString = "\(kind.defaultPort)"
        keyField.isEnabled = kind == .sftp
        keyButton.isEnabled = kind == .sftp
        insecureCheck.isEnabled = kind == .ftps
    }

    private func load(_ c: Connection) {
        editingID = c.id
        nameField.stringValue = c.name
        kindPopup.selectItem(at: Connection.Kind.allCases.firstIndex(of: c.kind) ?? 0)
        hostField.stringValue = c.host
        portField.stringValue = c.port == c.kind.defaultPort ? "" : "\(c.port)"
        userField.stringValue = c.user
        passwordField.stringValue = ConnectionStore.password(for: c) ?? ""
        keyField.stringValue = c.keyFile
        pathField.stringValue = c.path
        insecureCheck.state = c.allowInvalidCertificate ? .on : .off
        kindChanged(nil)
    }

    /// The connection described by the form (keeps the id of the one being edited).
    private func formConnection() -> Connection? {
        var host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        var user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        var kind = selectedKind
        // Accept "sftp://user@host:port/path" pasted into the host field.
        if let u = URL(string: host), let scheme = u.scheme, let k = Connection.Kind(rawValue: scheme.lowercased()), let h = u.host {
            kind = k
            host = h
            if let pu = u.user, user.isEmpty { user = pu }
            if let p = u.port, portField.stringValue.isEmpty { portField.stringValue = "\(p)" }
            if !u.path.isEmpty, pathField.stringValue.isEmpty { pathField.stringValue = u.path }
        } else if let at = host.firstIndex(of: "@"), user.isEmpty {
            user = String(host[..<at])
            host = String(host[host.index(after: at)...])
        }
        guard !host.isEmpty else {
            Dialogs.error("Missing host", "Enter the server name or address.")
            return nil
        }
        if kind == .sftp && user.isEmpty { user = NSUserName() }
        let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? kind.defaultPort
        var c = Connection(name: nameField.stringValue.trimmingCharacters(in: .whitespaces), kind: kind, host: host, port: port,
                           user: user, keyFile: keyField.stringValue.trimmingCharacters(in: .whitespaces),
                           path: pathField.stringValue.trimmingCharacters(in: .whitespaces),
                           allowInvalidCertificate: insecureCheck.state == .on)
        if let editingID { c.id = editingID }
        return c
    }

    @objc private func newConnection(_ sender: Any?) {
        table.deselectAll(nil)
        load(Connection(name: "", kind: .sftp, host: "", port: 22, user: ""))
        editingID = nil
        window?.makeFirstResponder(hostField)
    }

    @objc private func saveConnection(_ sender: Any?) {
        guard let c = formConnection() else { return }
        var list = ConnectionStore.all
        if let i = list.firstIndex(where: { $0.id == c.id }) { list[i] = c } else { list.append(c) }
        ConnectionStore.all = list
        ConnectionStore.setPassword(savePassword.state == .on ? passwordField.stringValue : nil, for: c)
        editingID = c.id
        connections = list
        table.reloadData()
        if let i = connections.firstIndex(where: { $0.id == c.id }) { table.selectRowIndexes([i], byExtendingSelection: false) }
    }

    @objc private func deleteConnection(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0, row < connections.count else { return }
        let c = connections[row]
        guard Dialogs.confirm("Delete connection", "Delete \"\(c.label)\" and its saved password?", ok: "Delete") else { return }
        ConnectionStore.remove(c)
        connections = ConnectionStore.all
        table.reloadData()
        newConnection(nil)
    }

    @objc private func chooseKey(_ sender: Any?) {
        let p = NSOpenPanel()
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        p.showsHiddenFiles = true
        p.message = "Choose a private key"
        if p.runModal() == .OK, let u = p.url { keyField.stringValue = u.abbreviatedPath }
    }

    @objc private func connect(_ sender: Any?) {
        guard let c = formConnection() else { return }
        if c.id == editingID, ConnectionStore.all.contains(where: { $0.id == c.id }), savePassword.state == .on {
            ConnectionStore.setPassword(passwordField.stringValue, for: c)
        }
        controller?.connect(c, password: passwordField.stringValue, inNewTab: newTabCheck.state == .on)
        window?.close()
    }

    @objc private func closeWindow(_ sender: Any?) { window?.close() }

    func numberOfRows(in tableView: NSTableView) -> Int { connections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tf = NSTextField(labelWithString: "")
        let c = connections[row]
        tf.stringValue = "\(c.label)  (\(c.kind.rawValue))"
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if row >= 0, row < connections.count { load(connections[row]) }
    }
}

extension MainWindowController {
    /// Opens a connection in the active panel.
    func connect(_ c: Connection, password: String?, inNewTab: Bool) {
        let pw = password ?? ConnectionStore.password(for: c) ?? ""
        let fs: RemoteFileSystem
        switch c.kind {
        case .sftp:
            fs = SFTPFileSystem(host: c.host, port: c.port, user: c.user, password: pw, keyFile: c.keyFile, initialPath: c.path)
        case .ftp, .ftps:
            fs = FTPFileSystem(host: c.host, port: c.port, user: c.user, password: pw, tls: c.kind == .ftps,
                               allowInvalidCertificate: c.allowInvalidCertificate, initialPath: c.path)
        }
        let panel = active!
        let job = RemoteJob(title: "Connecting to \(c.host)", fs: fs) { job in
            job.progress("\(c.kind.rawValue)://\(c.user.isEmpty ? "" : c.user + "@")\(c.host):\(c.port)", 0, "Connecting…")
            do {
                if let s = fs as? SFTPFileSystem { try s.connect() }
                if let f = fs as? FTPFileSystem { try f.connect() }
            } catch {
                _ = job.fail("Cannot connect to \(c.host)\n\n\(error.localizedDescription)")
            }
        }
        job.start(on: window) { [weak self] in
            guard job.failures.isEmpty, !job.flag.isCancelled else {
                fs.close()
                return
            }
            panel.openRemote(fs, path: fs.initialPath, inNewTab: inNewTab)
            panel.activate()
        }
    }

    @objc func showConnections(_ sender: Any?) {
        ConnectionsWindowController.show(controller: self)
    }

    @objc func connectSaved(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let c = ConnectionStore.all.first(where: { $0.id == id }) else { return }
        connect(c, password: nil, inNewTab: true)
    }

    @objc func disconnect(_ sender: Any?) {
        guard active.isRemote else { NSSound.beep(); return }
        if active.tabs.count > 1 {
            active.closeTab()
        } else {
            active.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    /// Rebuilds the Net menu with the saved connections.
    @objc func rebuildNetMenu(_ n: Notification? = nil) {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Net" })?.submenu else { return }
        menu.removeAllItems()
        let connect = NSMenuItem(title: "Connect to Server…", action: #selector(showConnections(_:)), keyEquivalent: "k")
        connect.target = self
        menu.addItem(connect)
        let disconnect = NSMenuItem(title: "Disconnect", action: #selector(disconnect(_:)), keyEquivalent: "k")
        disconnect.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(disconnect)
        let saved = ConnectionStore.all
        if !saved.isEmpty {
            menu.addItem(.separator())
            for c in saved {
                let mi = NSMenuItem(title: c.label, action: #selector(connectSaved(_:)), keyEquivalent: "")
                mi.representedObject = c.id
                mi.toolTip = "\(c.kind.rawValue)://\(c.user)@\(c.host):\(c.port)\(c.path)"
                mi.image = NSImage(systemSymbolName: c.kind == .sftp ? "lock.shield" : "network", accessibilityDescription: nil)
                menu.addItem(mi)
            }
        }
    }
}
