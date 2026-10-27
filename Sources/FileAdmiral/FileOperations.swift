import AppKit
import Darwin

/// Progress dialog shown as a sheet during long operations.
final class ProgressSheet: NSWindowController {
    let flag = CancelFlag()
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let fromLabel = NSTextField(labelWithString: "")
    private let toLabel = NSTextField(labelWithString: "")
    private let fileBar = NSProgressIndicator()
    private let totalBar = NSProgressIndicator()
    private let infoLabel = NSTextField(labelWithString: "")
    private weak var parentWindow: NSWindow?

    init(title: String, indeterminate: Bool = false, showFileBar: Bool = true) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 170), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title
        super.init(window: panel)

        titleLabel.stringValue = title
        titleLabel.font = Theme.boldFont
        for l in [fromLabel, toLabel, infoLabel] {
            l.font = Theme.smallFont
            l.lineBreakMode = .byTruncatingMiddle
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for bar in [fileBar, totalBar] {
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 1
            bar.isIndeterminate = indeterminate
        }
        fileBar.isHidden = !showFileBar || indeterminate
        if indeterminate { totalBar.startAnimation(nil) }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [titleLabel, fromLabel, toLabel, fileBar, totalBar, infoLabel, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            fileBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            totalBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            fromLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            toLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            infoLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            panel.contentView!.widthAnchor.constraint(equalToConstant: 500),
        ])
        stack.setCustomSpacing(12, after: infoLabel)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -18).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func begin(on parent: NSWindow?) {
        parentWindow = parent
        guard let w = window else { return }
        if let parent {
            parent.beginSheet(w)
        } else {
            w.center()
            showWindow(nil)
        }
    }

    func end() {
        guard let w = window else { return }
        if let p = parentWindow, w.sheetParent != nil {
            p.endSheet(w)
        }
        w.orderOut(nil)
    }

    /// Also called for every progress update (used by the Background Operations window).
    var onUpdate: ((_ from: String, _ total: Double, _ info: String) -> Void)?

    func update(from: String, to: String, file: Double, total: Double, info: String) {
        fromLabel.stringValue = from
        toLabel.stringValue = to
        fileBar.doubleValue = file
        totalBar.doubleValue = total
        infoLabel.stringValue = info
        onUpdate?(from, total, info)
    }

    func setInfo(_ s: String) {
        infoLabel.stringValue = s
        onUpdate?(fromLabel.stringValue, totalBar.doubleValue, s)
    }

    var title: String { window?.title ?? "" }

    @objc private func cancelPressed(_ sender: Any?) {
        flag.cancel()
        infoLabel.stringValue = "Cancelling…"
        onCancel?()
    }
}

/// Base class for background file jobs: error prompting and lifetime management.
class FileJob {
    fileprivate static var running: [FileJob] = []
    let sheet: ProgressSheet
    fileprivate var skipAllErrors = false
    var flag: CancelFlag { sheet.flag }

    init(title: String) {
        sheet = ProgressSheet(title: title)
    }

    /// Runs the job. In the background it goes to the serial Background Operations queue (no sheet).
    func start(on window: NSWindow?, background: Bool = false, completion: @escaping () -> Void) {
        if background {
            BackgroundQueue.shared.add(self, completion: completion)
            return
        }
        FileJob.running.append(self)
        sheet.begin(on: window)
        DispatchQueue.global(qos: .userInitiated).async {
            self.run()
            DispatchQueue.main.async {
                self.sheet.end()
                FileJob.running.removeAll { $0 === self }
                completion()
            }
        }
    }

    func run() {}

    /// Asks the user what to do after an error. Returns false when the job should stop.
    /// Self-test hooks: when set, errors are recorded instead of shown, and overwrite questions get this answer.
    static var testErrors: [String]?
    static var testOverwrite = true

    func reportError(_ message: String) -> Bool {
        if FileJob.testErrors != nil {
            DispatchQueue.main.async { FileJob.testErrors?.append(message) }
            return true
        }
        if skipAllErrors { return true }
        if flag.isCancelled { return false }
        var result = true
        DispatchQueue.main.sync {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Error"
            a.informativeText = message
            a.addButton(withTitle: "Skip")
            a.addButton(withTitle: "Skip All")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: result = true
            case .alertSecondButtonReturn: skipAllErrors = true; result = true
            default: result = false
            }
        }
        if !result { flag.cancel() }
        return result
    }

    static func posixError(_ what: String, _ path: String) -> String {
        "\(what) \(path)\n\(String(cString: strerror(errno)))"
    }
}

final class TransferJob: FileJob {
    private enum Policy { case ask, overwriteAll, skipAll, overwriteOlder }
    private enum Answer { case overwrite, skip, cancel }

    private let sources: [URL]
    private let destDir: URL
    private let newName: String?
    private let move: Bool
    private let mask: FileMask?
    private var policy: Policy = .ask
    private var total: Int64 = 0
    private var done: Int64 = 0
    private var lastUI = Date.distantPast
    private(set) var completedSources: [URL] = []
    /// Top-level items this job created (or moved) at a destination that was free before: (source, destination).
    /// Used for Undo; items that replaced or merged into existing ones are not included.
    private(set) var undoPairs: [(source: URL, destination: URL)] = []
    var isMove: Bool { move }

    init(sources: [URL], destDir: URL, newName: String?, move: Bool, mask: FileMask? = nil, overwriteAll: Bool = false) {
        self.sources = sources
        self.destDir = destDir
        self.newName = newName
        self.move = move
        self.mask = mask?.matchesEverything == true ? nil : mask
        super.init(title: move ? "Moving" : "Copying")
        if overwriteAll { policy = .overwriteAll }
    }

    override func run() {
        let fm = FileManager.default
        if !destDir.isExistingDirectory {
            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            } catch {
                _ = reportError("Cannot create \(destDir.path)\n\(error.localizedDescription)")
                return
            }
        }

        var remaining: [(URL, URL)] = []
        for src in sources {
            if flag.isCancelled { return }
            let dst = destDir.appendingPathComponent(newName ?? src.lastPathComponent)
            if src.standardizedFileURL.path == dst.standardizedFileURL.path {
                if !reportError("Cannot copy \"\(src.lastPathComponent)\" onto itself.") { return }
                continue
            }
            if isInside(dst, src) {
                if !reportError("Cannot copy or move the folder \"\(src.lastPathComponent)\" into itself.") { return }
                continue
            }
            if pathExists(dst) && isSameFile(src, dst) {
                // Same inode: either a case-only rename on a case-insensitive volume, or two hard links.
                if src.path.lowercased() == dst.path.lowercased() && move && Darwin.rename(src.path, dst.path) == 0 {
                    completedSources.append(src)
                    undoPairs.append((src, dst))
                } else if !reportError("\"\(src.lastPathComponent)\" and \"\(dst.path)\" are the same file.") {
                    return
                }
                continue
            }
            if move && mask == nil && !pathExists(dst) {
                // Fast path on the same volume. RENAME_EXCL never replaces a file that appeared meanwhile.
                if renamex_np(src.path, dst.path, renameExclusive) == 0 {
                    completedSources.append(src)
                    undoPairs.append((src, dst))
                    tick(src.path, dst.path, file: 1)
                    continue
                }
                if errno != EXDEV && errno != EEXIST {
                    if !reportError(FileJob.posixError("Cannot move", src.path)) { return }
                    continue
                }
            }
            remaining.append((src, dst))
        }

        DispatchQueue.main.async { self.sheet.setInfo("Calculating size…") }
        for (src, _) in remaining {
            if flag.isCancelled { return }
            total += FileItem.totalSize(of: src)
        }

        for (src, dst) in remaining {
            if flag.isCancelled { return }
            let existedBefore = pathExists(dst)
            let ok = copyItem(src, dst)
            if ok {
                completedSources.append(src)
                if !existedBefore && mask == nil { undoPairs.append((src, dst)) }
                // With a mask, matching files are deleted one by one inside copyItem.
                if move && mask == nil {
                    do {
                        try fm.removeItem(at: src)
                    } catch {
                        if !reportError("Cannot delete source \(src.path)\n\(error.localizedDescription)") { return }
                    }
                }
            }
        }
    }

    /// RENAME_EXCL from <sys/stdio.h>: fail with EEXIST instead of replacing the target.
    private let renameExclusive: UInt32 = 0x00000004

    /// Resolved absolute path; for a path that doesn't exist yet, its parent is resolved.
    private func realPath(_ url: URL) -> String {
        if let r = realpath(url.path, nil) {
            defer { free(r) }
            return String(cString: r)
        }
        return realPath(url.deletingLastPathComponent()) + "/" + url.lastPathComponent
    }

    /// True when `dst` would be inside folder `src` (following symlinks, honoring case-insensitive volumes).
    private func isInside(_ dst: URL, _ src: URL) -> Bool {
        var st = stat()
        guard lstat(src.path, &st) == 0, (st.st_mode & 0o170000) == 0o040000 else { return false }
        let d = realPath(dst), s = realPath(src) + "/"
        if d.hasPrefix(s) { return true }
        let caseSensitive = (try? src.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        return !caseSensitive && d.lowercased().hasPrefix(s.lowercased())
    }

    private func tick(_ from: String, _ to: String, file: Double) {
        let now = Date()
        if now.timeIntervalSince(lastUI) < 0.05 && file < 1 { return }
        lastUI = now
        let t = total > 0 ? Double(done) / Double(total) : (file >= 1 ? 1 : 0)
        let info = "\(Fmt.bytes(done)) of \(Fmt.bytes(total))"
        DispatchQueue.main.async {
            self.sheet.update(from: from, to: "→ " + to, file: file, total: t, info: info)
        }
    }

    /// Recursively copies `src` to `dst`. Returns true when everything was copied.
    private func copyItem(_ src: URL, _ dst: URL) -> Bool {
        if flag.isCancelled { return false }
        let fm = FileManager.default
        var st = stat()
        guard lstat(src.path, &st) == 0 else {
            return reportError(FileJob.posixError("Cannot read", src.path)) && false
        }
        let type = st.st_mode & 0o170000
        var dstStat = stat()
        let dstExists = lstat(dst.path, &dstStat) == 0
        let dstType = dstStat.st_mode & 0o170000

        if type == 0o040000 {
            // List the source first, so a destination created inside it can never be copied again.
            let names: [String]
            do {
                names = try fm.contentsOfDirectory(atPath: src.path)
            } catch {
                _ = reportError("Cannot read \(src.path)\n\(error.localizedDescription)")
                return false
            }
            var created = false
            if dstExists {
                // lstat: a symlink at the destination is not a folder to merge into.
                if dstType != 0o040000 {
                    _ = reportError("Cannot overwrite \(dst.path) with a folder.")
                    return false
                }
            } else {
                do {
                    try fm.createDirectory(at: dst, withIntermediateDirectories: false)
                    created = true
                } catch {
                    _ = reportError("Cannot create \(dst.path)\n\(error.localizedDescription)")
                    return false
                }
            }
            var ok = true
            for n in names {
                if flag.isCancelled { return false }
                if !copyItem(src.appendingPathComponent(n), dst.appendingPathComponent(n)) { ok = false }
            }
            _ = copyfile(src.path, dst.path, nil, copyfile_flags_t(1 | 2 | 4)) // ACL | STAT | XATTR
            if mask != nil {
                // Don't leave empty folders behind for subtrees without matching files.
                if created, (try? fm.contentsOfDirectory(atPath: dst.path))?.isEmpty == true { rmdir(dst.path) }
                if move, (try? fm.contentsOfDirectory(atPath: src.path))?.isEmpty == true { rmdir(src.path) }
            }
            return ok
        }

        if let mask, !mask.matches(src.lastPathComponent) {
            return false
        }
        guard type == 0o100000 || type == 0o120000 else {
            _ = reportError("Skipped special file (pipe, socket or device): \(src.path)")
            return false
        }

        var replacing = false
        if dstExists {
            switch askOverwrite(src, dst) {
            case .skip:
                done += Int64(st.st_size)
                return false
            case .cancel:
                flag.cancel()
                return false
            case .overwrite:
                if dstType == 0o040000 {
                    _ = reportError("Cannot overwrite folder \(dst.path) with a file.")
                    return false
                }
                replacing = true
            }
        }

        // Write to a temporary name next to the target, then rename it into place: the old file
        // survives any failure or cancellation, and a half-written file never appears under the real name.
        let temp = dst.deletingLastPathComponent().appendingPathComponent(temporaryName(for: dst.lastPathComponent))
        let written: Bool
        if type == 0o120000 {
            do {
                let target = try fm.destinationOfSymbolicLink(atPath: src.path)
                try fm.createSymbolicLink(atPath: temp.path, withDestinationPath: target)
                written = true
            } catch {
                _ = reportError("Cannot copy link \(src.path)\n\(error.localizedDescription)")
                written = false
            }
        } else {
            written = copyFileData(src, temp, size: Int64(st.st_size), mode: st.st_mode)
        }
        guard written else {
            unlink(temp.path)
            return false
        }
        let renamed = replacing ? Darwin.rename(temp.path, dst.path) : renamex_np(temp.path, dst.path, renameExclusive)
        if renamed != 0 {
            let message = FileJob.posixError("Cannot create", dst.path)
            unlink(temp.path)
            _ = reportError(message)
            return false
        }
        if move && mask != nil && unlink(src.path) != 0 {
            _ = reportError(FileJob.posixError("Cannot delete source", src.path))
        }
        return true
    }

    private func copyFileData(_ src: URL, _ dst: URL, size: Int64, mode: mode_t) -> Bool {
        tick(src.path, dst.path, file: 0)
        // APFS clone: instant copy on the same volume.
        if clonefile(src.path, dst.path, 0) == 0 {
            done += size
            tick(src.path, dst.path, file: 1)
            return true
        }
        // O_NONBLOCK guards against hanging on anything that isn't a plain file.
        let inFd = Darwin.open(src.path, O_RDONLY | O_NONBLOCK)
        guard inFd >= 0 else {
            _ = reportError(FileJob.posixError("Cannot open", src.path))
            return false
        }
        defer { Darwin.close(inFd) }
        _ = fcntl(inFd, F_SETFL, 0)
        let outFd = Darwin.open(dst.path, O_WRONLY | O_CREAT | O_EXCL, mode & 0o777 | 0o200)
        guard outFd >= 0 else {
            _ = reportError(FileJob.posixError("Cannot create", dst.path))
            return false
        }
        let bufSize = 4 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        var fileDone: Int64 = 0
        var failed = false
        while true {
            if flag.isCancelled { failed = true; break }
            let n = read(inFd, buf, bufSize)
            if n < 0 {
                if errno == EINTR { continue }
                _ = reportError(FileJob.posixError("Read error", src.path))
                failed = true
                break
            }
            if n == 0 { break }
            var off = 0
            while off < n {
                let w = write(outFd, buf + off, n - off)
                if w < 0 {
                    if errno == EINTR { continue }
                    _ = reportError(FileJob.posixError("Write error", dst.path))
                    failed = true
                    break
                }
                off += w
            }
            if failed { break }
            fileDone += Int64(n)
            done += Int64(n)
            tick(src.path, dst.path, file: size > 0 ? Double(fileDone) / Double(size) : 1)
        }
        // Network volumes and full disks may only report write errors on close.
        if Darwin.close(outFd) != 0 && !failed {
            _ = reportError(FileJob.posixError("Write error", dst.path))
            failed = true
        }
        if failed {
            unlink(dst.path)
            return false
        }
        _ = copyfile(src.path, dst.path, nil, copyfile_flags_t(1 | 2 | 4))
        tick(src.path, dst.path, file: 1)
        return true
    }

    private func askOverwrite(_ src: URL, _ dst: URL) -> Answer {
        let sItem = FileItem.make(src), dItem = FileItem.make(dst)
        switch policy {
        case .overwriteAll: return .overwrite
        case .skipAll: return .skip
        case .overwriteOlder:
            return (sItem?.modified ?? .distantPast) > (dItem?.modified ?? .distantPast) ? .overwrite : .skip
        case .ask: break
        }
        if FileJob.testErrors != nil { return FileJob.testOverwrite ? .overwrite : .skip }
        var answer = Answer.cancel
        DispatchQueue.main.sync {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "File exists!"
            func describe(_ it: FileItem?) -> String {
                guard let it else { return "" }
                return "\(Fmt.int(it.size)) bytes   \(Fmt.date(it.modified))"
            }
            a.informativeText = "Overwrite:\n\(dst.path)\n\(describe(dItem))\n\nWith file:\n\(src.path)\n\(describe(sItem))"
            a.addButton(withTitle: "Overwrite")
            a.addButton(withTitle: "Skip")
            a.addButton(withTitle: "Overwrite All")
            a.addButton(withTitle: "Skip All")
            a.addButton(withTitle: "Overwrite All Older")
            a.addButton(withTitle: "Cancel")
            switch a.runModal().rawValue {
            case 1000: answer = .overwrite
            case 1001: answer = .skip
            case 1002: policy = .overwriteAll; answer = .overwrite
            case 1003: policy = .skipAll; answer = .skip
            case 1004:
                policy = .overwriteOlder
                answer = (sItem?.modified ?? .distantPast) > (dItem?.modified ?? .distantPast) ? .overwrite : .skip
            default: answer = .cancel
            }
        }
        return answer
    }
}

final class DeleteJob: FileJob {
    private let urls: [URL]
    private let permanent: Bool
    /// (original location, location in the Trash) for Undo.
    private(set) var trashed: [(original: URL, inTrash: URL)] = []

    init(urls: [URL], permanent: Bool) {
        self.urls = urls
        self.permanent = permanent
        super.init(title: permanent ? "Deleting" : "Moving to Trash")
    }

    override func run() {
        let fm = FileManager.default
        for (i, u) in urls.enumerated() {
            if flag.isCancelled { return }
            let frac = Double(i) / Double(max(urls.count, 1))
            DispatchQueue.main.async {
                self.sheet.update(from: u.path, to: "", file: 0, total: frac, info: "\(i + 1) of \(self.urls.count)")
            }
            do {
                if permanent {
                    try fm.removeItem(at: u)
                } else {
                    var result: NSURL?
                    try fm.trashItem(at: u, resultingItemURL: &result)
                    if let r = result as URL? { trashed.append((u, r)) }
                }
            } catch {
                if !reportError("Cannot delete \(u.path)\n\(error.localizedDescription)") { return }
            }
        }
    }
}

/// Hidden temporary name used next to `name` while a file is being written, kept within the 255-byte
/// file name limit (the original name is only there to make leftovers recognizable).
func temporaryName(for name: String, prefix: String = ".fileadmiral-") -> String {
    let head = prefix + UUID().uuidString.prefix(8) + "-"
    var tail = Substring(name)
    while !tail.isEmpty && (head + tail).utf8.count > 255 { tail.removeLast() }
    return head + tail
}

/// Runs an external tool (zip, tar, shell commands) with a cancellable progress sheet.
enum TaskRunner {
    private static var sheets: [ProgressSheet] = []

    static func run(title: String, executable: String, arguments: [String], cwd: URL, window: NSWindow?,
                    environment: [String: String]? = nil, completion: @escaping (Int32, String) -> Void) {
        let sheet = ProgressSheet(title: title, indeterminate: true, showFileBar: false)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        if let environment { p.environment = environment }
        sheet.onCancel = { p.terminate() }
        do {
            try p.run()
        } catch {
            completion(-1, error.localizedDescription)
            return
        }
        sheets.append(sheet)
        sheet.update(from: arguments.joined(separator: " "), to: "", file: 0, total: 0, info: "")
        // Avoid flashing the sheet for very short tasks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if p.isRunning && sheets.contains(where: { $0 === sheet }) { sheet.begin(on: window) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                sheet.end()
                sheets.removeAll { $0 === sheet }
                completion(p.terminationStatus, out)
            }
        }
    }
}
