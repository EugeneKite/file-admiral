import AppKit

/// Background job for FTP/SFTP work, with the usual progress sheet. Cancel aborts the running command.
final class RemoteJob: FileJob {
    private enum Policy { case ask, overwriteAll, skipAll }
    enum Answer { case overwrite, skip, cancel }

    private let work: (RemoteJob) -> Void
    private var policy: Policy = .ask
    private(set) var failures: [String] = []

    init(title: String, fs: RemoteFileSystem, work: @escaping (RemoteJob) -> Void) {
        self.work = work
        super.init(title: title)
        sheet.onCancel = { [weak fs] in fs?.cancelCurrent() }
    }

    override func run() { work(self) }

    func progress(_ text: String, _ fraction: Double, _ info: String) {
        DispatchQueue.main.async { self.sheet.update(from: text, to: "", file: 0, total: fraction, info: info) }
    }

    /// Reports an error; returns false when the user chose to stop.
    func fail(_ message: String) -> Bool {
        failures.append(message)
        return reportError(message)
    }

    func askOverwrite(_ name: String, existing: String) -> Answer {
        switch policy {
        case .overwriteAll: return .overwrite
        case .skipAll: return .skip
        case .ask: break
        }
        if FileJob.testErrors != nil { return FileJob.testOverwrite ? .overwrite : .skip }
        var answer = Answer.cancel
        DispatchQueue.main.sync {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "File exists!"
            a.informativeText = "\"\(name)\" already exists in\n\(existing)\n\nReplace it?"
            a.addButton(withTitle: "Overwrite")
            a.addButton(withTitle: "Skip")
            a.addButton(withTitle: "Overwrite All")
            a.addButton(withTitle: "Skip All")
            a.addButton(withTitle: "Cancel")
            switch a.runModal().rawValue {
            case 1000: answer = .overwrite
            case 1001: answer = .skip
            case 1002: policy = .overwriteAll; answer = .overwrite
            case 1003: policy = .skipAll; answer = .skip
            default: answer = .cancel
            }
        }
        if answer == .cancel { flag.cancel() }
        return answer
    }
}

extension MainWindowController {
    /// Shows a message for commands that only work on local folders. Returns true when blocked.
    func blockedOnRemote(_ command: String) -> Bool {
        guard active.isRemote else { return false }
        Dialogs.info(command, "\(command) is not available on FTP/SFTP panels.")
        return true
    }

    /// Closes a connection once no tab (other than the one being closed) uses it any more.
    func releaseConnection(_ fs: RemoteFileSystem, closingTabOf panel: FilePanel, at index: Int) {
        var users = 0
        for p in [left!, right!] {
            for (i, t) in p.tabs.enumerated() where t.remote === fs && !(p === panel && i == index) { users += 1 }
        }
        if users == 0 {
            DispatchQueue.global().async { fs.close() }
        }
    }

    // MARK: Open / view / edit remote files

    private func temporaryFolder(_ purpose: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileAdmiral-\(purpose)/\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Downloads one remote file to a temporary folder, then calls `done` with the local copy.
    func fetchRemoteFile(_ item: FileItem, from panel: FilePanel, purpose: String, done: @escaping (URL) -> Void) {
        guard let fs = panel.remote else { return }
        let local = temporaryFolder(purpose).appendingPathComponent(item.name)
        let remotePath = item.url.path
        let job = RemoteJob(title: "Downloading", fs: fs) { job in
            job.progress(fs.title + remotePath, 0, "")
            do {
                try fs.download(remotePath, isDirectory: false, to: local)
            } catch {
                _ = job.fail("Cannot download \(item.name)\n\(error.localizedDescription)")
            }
        }
        job.start(on: window) {
            if job.failures.isEmpty && FileManager.default.fileExists(atPath: local.path) { done(local) }
        }
    }

    func openRemoteFile(_ item: FileItem, from panel: FilePanel) {
        fetchRemoteFile(item, from: panel, purpose: "Open") { NSWorkspace.shared.open($0) }
    }

    func viewRemoteFile(_ item: FileItem) {
        fetchRemoteFile(item, from: active, purpose: "View") { ViewerWindowController.show(url: $0) }
    }

    /// F4 on a remote file: edit a local copy; every save is uploaded back (like TC's FTP edit).
    func editRemoteFile(_ item: FileItem) {
        guard let fs = active.remote else { return }
        let remotePath = item.url.path
        let panel = active!
        fetchRemoteFile(item, from: panel, purpose: "Edit") { [weak self] local in
            self?.openInEditorForRemote(local)
            RemoteEditWatcher.watch(local: local, remotePath: remotePath, fs: fs) { message in
                panel.showTransientStatus(message)
            }
        }
    }

    // MARK: Transfers

    /// Copy/move involving an FTP/SFTP panel. `destination` is the folder in `destPanel`.
    func remoteTransfer(_ items: [FileItem], from source: FilePanel, to destPanel: FilePanel, move: Bool) {
        let srcFS = source.remote, dstFS = destPanel.remote
        if let s = srcFS, let d = dstFS {
            guard s === d else {
                Dialogs.error("Not supported", "Copying directly between two different servers isn't supported. Copy to a local folder first.")
                return
            }
            guard move else {
                Dialogs.error("Not supported", "Copying within the same server isn't supported by FTP/SFTP. Move (F6) works.")
                return
            }
            let destDir = destPanel.remotePath
            runRemote(title: "Moving", fs: s, items: items, refresh: [source, destPanel]) { job, item, fraction in
                job.progress(item.url.path, fraction, "")
                try s.rename(item.url.path, to: RemotePath.join(destDir, item.name))
            }
            return
        }
        if let s = srcFS {
            // Download
            let destDir = destPanel.currentURL
            runRemote(title: move ? "Downloading and deleting" : "Downloading", fs: s, items: items, refresh: [source, destPanel]) {
                job, item, fraction in
                let dst = destDir.appendingPathComponent(item.name)
                job.progress("\(s.title)\(item.url.path) → \(dst.path)", fraction, "")
                var replace = false
                if pathExists(dst) {
                    if item.isDirectory || dst.isExistingDirectory {
                        throw RemoteError(message: "\"\(item.name)\" already exists in \(destDir.path); folders are not merged.")
                    }
                    switch job.askOverwrite(item.name, existing: destDir.path) {
                    case .overwrite: replace = true
                    case .skip, .cancel: return
                    }
                }
                // Download next to the target and rename into place, so a failed download never destroys the old file.
                let temp = destDir.appendingPathComponent(temporaryName(for: item.name))
                do {
                    try s.download(item.url.path, isDirectory: item.isDirectory, to: temp)
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    throw error
                }
                let renamed = replace ? rename(temp.path, dst.path) : renamex_np(temp.path, dst.path, 0x4)
                if renamed != 0 {
                    try? FileManager.default.removeItem(at: temp)
                    throw RemoteError(message: "Cannot create \(dst.path): \(String(cString: strerror(errno)))")
                }
                if move { try s.delete(item.url.path, isDirectory: item.isDirectory) }
            }
            return
        }
        if let d = dstFS {
            // Upload
            let destDir = destPanel.remotePath
            let existing = Set(destPanel.items.map(\.name))
            runRemote(title: move ? "Uploading and deleting" : "Uploading", fs: d, items: items, refresh: [source, destPanel]) {
                job, item, fraction in
                let dst = RemotePath.join(destDir, item.name)
                job.progress("\(item.url.path) → \(d.title)\(dst)", fraction, "")
                if existing.contains(item.name) {
                    if item.isDirectory {
                        throw RemoteError(message: "\"\(item.name)\" already exists on the server; folders are not merged.")
                    }
                    switch job.askOverwrite(item.name, existing: d.title + destDir) {
                    case .overwrite: break
                    case .skip, .cancel: return
                    }
                }
                try d.upload(item.url, to: dst)
                if move { try FileManager.default.removeItem(at: item.url) }
            }
        }
    }

    /// Runs `step` for each item in a RemoteJob, then refreshes the panels.
    private func runRemote(title: String, fs: RemoteFileSystem, items: [FileItem], refresh panels: [FilePanel],
                           step: @escaping (RemoteJob, FileItem, Double) throws -> Void) {
        let job = RemoteJob(title: title, fs: fs) { job in
            for (i, item) in items.enumerated() {
                if job.flag.isCancelled { return }
                do {
                    try step(job, item, Double(i) / Double(max(items.count, 1)))
                } catch {
                    if job.flag.isCancelled { return }
                    if !job.fail("\(item.name): \(error.localizedDescription)") { return }
                }
            }
        }
        job.start(on: window) {
            for p in panels {
                p.unmark(items.map(\.name))
                p.reload()
            }
        }
    }

    func remoteDelete(_ items: [FileItem]) {
        guard let fs = active.remote else { return }
        let what = items.count == 1 ? "\"\(items[0].name)\"" : "\(items.count) items"
        if FileJob.testErrors == nil {
            guard Dialogs.confirm("Delete", "Do you really want to permanently delete \(what) from \(fs.title)?\nThis cannot be undone.",
                                  ok: "Delete", destructive: true) else { return }
        }
        runRemote(title: "Deleting", fs: fs, items: items, refresh: [active]) { job, item, fraction in
            job.progress(fs.title + item.url.path, fraction, "")
            try fs.delete(item.url.path, isDirectory: item.isDirectory)
        }
    }

    func remoteMakeDirectory(_ name: String) {
        guard let fs = active.remote else { return }
        let path = name.hasPrefix("/") ? name : RemotePath.join(active.remotePath, name)
        let panel = active!
        let job = RemoteJob(title: "Creating folder", fs: fs) { job in
            do { try fs.makeDirectory(path) } catch { _ = job.fail(error.localizedDescription) }
        }
        job.start(on: window) {
            if !job.failures.isEmpty { return }
            panel.reload(selectName: (path as NSString).lastPathComponent)
        }
    }

    func remoteRename(_ item: FileItem, to name: String) {
        guard let fs = active.remote else { return }
        let target = name.hasPrefix("/") ? name : RemotePath.join(RemotePath.parent(item.url.path), name)
        if active.items.contains(where: { $0.name == name }) && name != item.name {
            Dialogs.error("Cannot rename", "\"\(name)\" already exists.")
            return
        }
        let panel = active!
        let job = RemoteJob(title: "Renaming", fs: fs) { job in
            do { try fs.rename(item.url.path, to: target) } catch { _ = job.fail(error.localizedDescription) }
        }
        job.start(on: window) { panel.reload(selectName: (target as NSString).lastPathComponent) }
    }
}

/// Uploads a remotely edited file back to the server whenever it is saved locally.
final class RemoteEditWatcher {
    private static var active: [RemoteEditWatcher] = []

    private let local: URL
    private let remotePath: String
    private weak var fs: RemoteFileSystem?
    private let report: (String) -> Void
    private var lastModified: Date?
    private var timer: Timer?
    private let started = Date()

    static func watch(local: URL, remotePath: String, fs: RemoteFileSystem, report: @escaping (String) -> Void) {
        let w = RemoteEditWatcher(local: local, remotePath: remotePath, fs: fs, report: report)
        active.append(w)
    }

    private init(local: URL, remotePath: String, fs: RemoteFileSystem, report: @escaping (String) -> Void) {
        self.local = local
        self.remotePath = remotePath
        self.fs = fs
        self.report = report
        lastModified = Self.modified(local)
        // Editors often save by replacing the file, so poll the modification date rather than watching the inode.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.check() }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func stop() {
        timer?.invalidate()
        Self.active.removeAll { $0 === self }
    }

    private func check() {
        // Stop after 12 hours or when the connection is gone.
        guard let fs, Date().timeIntervalSince(started) < 12 * 3600 else { stop(); return }
        guard let m = Self.modified(local), m != lastModified else { return }
        lastModified = m
        let local = self.local, remotePath = self.remotePath, report = self.report
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try fs.upload(local, to: remotePath)
                let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                DispatchQueue.main.async { report("Uploaded \(local.lastPathComponent) to \(fs.title) at \(time)") }
            } catch {
                DispatchQueue.main.async {
                    Dialogs.error("Upload of \(local.lastPathComponent) failed",
                                  error.localizedDescription + "\n\nYour changes are still in \(local.path).")
                }
            }
        }
    }
}
