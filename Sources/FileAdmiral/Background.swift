import AppKit

extension Notification.Name {
    static let backgroundJobsChanged = Notification.Name("FileAdmiralBackgroundJobsChanged")
}

/// Runs file jobs one after another in the background (TC's F2 "queue"), while the user keeps working.
final class BackgroundQueue {
    static let shared = BackgroundQueue()

    final class Entry {
        let job: FileJob
        var status = "Waiting…"
        var progress = 0.0
        var running = false
        init(job: FileJob) { self.job = job }
    }

    private(set) var entries: [Entry] = []
    private let queue = DispatchQueue(label: "FileAdmiral.background", qos: .utility)

    func add(_ job: FileJob, completion: @escaping () -> Void) {
        let entry = Entry(job: job)
        entries.append(entry)
        job.sheet.onUpdate = { [weak self, weak entry] from, total, info in
            guard let entry else { return }
            entry.status = [from, info].filter { !$0.isEmpty }.joined(separator: "  ·  ")
            entry.progress = total
            self?.changed()
        }
        changed()
        queue.async {
            DispatchQueue.main.async {
                entry.running = true
                entry.status = job.flag.isCancelled ? "Cancelled" : "Starting…"
                self.changed()
            }
            if !job.flag.isCancelled { job.run() }
            DispatchQueue.main.async {
                self.entries.removeAll { $0 === entry }
                self.changed()
                completion()
            }
        }
    }

    func cancel(_ entry: Entry) {
        entry.job.flag.cancel()
        (entry.job as? RemoteJob)?.sheet.onCancel?()
        entry.status = "Cancelling…"
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: .backgroundJobsChanged, object: nil)
    }
}

/// Commands → Background Operations: progress and Cancel for queued jobs.
final class BackgroundWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static var shared: BackgroundWindowController?
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No background operations.")

    static func show() {
        let c = shared ?? BackgroundWindowController()
        shared = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 260),
                         styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        w.title = "Background Operations"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        buildUI()
        w.center()
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: .backgroundJobsChanged, object: nil)
        changed(nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let col = NSTableColumn(identifier: .init("job"))
        col.title = "Queued and running (one at a time)"
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 54
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        emptyLabel.textColor = .secondaryLabelColor
        for v in [scroll, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    @objc private func changed(_ n: Notification?) {
        table.reloadData()
        emptyLabel.isHidden = !BackgroundQueue.shared.entries.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { BackgroundQueue.shared.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = BackgroundQueue.shared.entries[row]
        let title = NSTextField(labelWithString: entry.job.sheet.title + (entry.running ? "" : " (waiting)"))
        title.font = Theme.boldFont
        let status = NSTextField(labelWithString: entry.status)
        status.font = Theme.smallFont
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = !entry.running
        bar.doubleValue = entry.progress
        if !entry.running { bar.startAnimation(nil) }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed(_:)))
        cancel.tag = row
        cancel.controlSize = .small
        let left = NSStackView(views: [title, status, bar])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2
        bar.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        status.widthAnchor.constraint(lessThanOrEqualTo: left.widthAnchor).isActive = true
        let row = NSStackView(views: [left, cancel])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        return row
    }

    @objc private func cancelPressed(_ sender: NSButton) {
        let entries = BackgroundQueue.shared.entries
        guard sender.tag < entries.count else { return }
        BackgroundQueue.shared.cancel(entries[sender.tag])
    }
}
