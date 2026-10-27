import AppKit

/// Automated smoke test, run with FA_SELFTEST=<scratch dir>. Exercises panels, keyboard handling and
/// file operations through the same code paths as the UI, prints PASS/FAIL lines and quits.
final class SelfTest {
    private let c: MainWindowController
    private var savedFrame: NSRect?
    private var narrowOverflow = 0
    private let root: URL
    private var failures = 0
    private var steps: [(String, () -> Void)] = []
    private var widthsBefore: (CGFloat, CGFloat) = (0, 0)
    private var fullscreenChecked = false
    private var pluginOutput = ""
    private var backgroundDone = false
    private var remoteResults: [(Bool, String)] = []
    private var remoteEnv: Bool { ProcessInfo.processInfo.environment["FA_TEST_SSH_KEY"] != nil }
    /// SFTP serves the real file system, so the remote path and the disk path are the same.
    private var sftpArea: String { root.appendingPathComponent("sftp-panel").path }
    private var sftpDisk: String { sftpArea }
    private var ftpArea: String { "/panel" }
    private var ftpDisk: String { (ProcessInfo.processInfo.environment["FA_TEST_FTP_ROOT"] ?? "/nonexistent") + "/panel" }

    init(controller: MainWindowController, root: URL) {
        c = controller
        self.root = root
    }

    private func check(_ cond: Bool, _ what: String) {
        print("\(cond ? "PASS" : "FAIL"): \(what)")
        if !cond { failures += 1 }
    }

    private func key(_ code: UInt16, _ chars: String = "", _ mods: NSEvent.ModifierFlags = [], ignoring: String? = nil) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                       windowNumber: c.window?.windowNumber ?? 0, context: nil, characters: chars,
                                       charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: code) else { return }
        c.active.tableView.keyDown(with: e)
    }

    private func names(_ p: FilePanel) -> [String] { p.items.map(\.name) }

    func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try! fm.createDirectory(at: a.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: b, withIntermediateDirectories: true)
        try! "hello".write(to: a.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try! "world".write(to: a.appendingPathComponent("two.md"), atomically: true, encoding: .utf8)
        try! "deep".write(to: a.appendingPathComponent("sub/three.txt"), atomically: true, encoding: .utf8)
        try! Data(repeating: 7, count: 5_000_000).write(to: a.appendingPathComponent("big.bin"))

        steps = [
            ("toolbar overflow: narrow", {
                guard let w = self.c.window else { return }
                self.savedFrame = w.frame
                w.setFrame(NSRect(x: w.frame.minX, y: w.frame.minY, width: 720, height: w.frame.height), display: true)
                w.contentView?.layoutSubtreeIfNeeded()
                self.narrowOverflow = self.c.toolbarOverflowCount
                self.check(self.c.toolbarOverflowCount > 0, "narrow window moves toolbar commands into the » menu (\(self.c.toolbarOverflowCount))")
                print("SHOT", w.windowNumber)
                fflush(stdout)
            }),
            ("toolbar overflow: wide", {
                guard let w = self.c.window else { return }
                w.setFrame(NSRect(x: w.frame.minX, y: w.frame.minY, width: 2000, height: w.frame.height), display: true)
                w.contentView?.layoutSubtreeIfNeeded()
                self.check(self.c.toolbarOverflowCount < self.narrowOverflow,
                           "wider window brings commands back from the » menu (\(self.narrowOverflow) → \(self.c.toolbarOverflowCount))")
                print("SHOT", w.windowNumber)
                fflush(stdout)
                if let f = self.savedFrame { w.setFrame(f, display: true) }
            }),
            ("navigate", {
                self.c.left.navigate(to: a)
                self.c.right.navigate(to: b)
                self.c.window?.makeFirstResponder(self.c.left.tableView)
                self.check(self.c.active === self.c.left, "left panel active")
                self.check(self.names(self.c.left) == ["..", "sub", "big.bin", "one.txt", "two.md"],
                           "listing sorted dirs first: \(self.names(self.c.left))")
            }),
            ("keys", {
                self.key(125, String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))) // down
                self.check(self.c.left.cursorItem?.name == "sub", "down arrow moves cursor")
                self.key(36, "\r") // enter
                self.check(self.c.left.currentURL.lastPathComponent == "sub", "Enter opens folder")
                self.key(51, "\u{7f}") // backspace
                self.check(self.c.left.currentURL.lastPathComponent == "a" && self.c.left.cursorItem?.name == "sub",
                           "Backspace goes up and keeps cursor on folder")
                self.key(31, "o") // quick search 'o'
                self.check(self.c.left.cursorItem?.name == "one.txt", "quick search jumps to one.txt")
                self.key(53, "\u{1b}")
                self.check(self.c.left.quickSearch.isEmpty, "Esc ends quick search")
                self.key(114, String(Character(UnicodeScalar(UInt32(NSHelpFunctionKey))!))) // Insert
                self.check(self.c.left.marked == ["one.txt"], "Insert marks file")
                self.check(self.c.left.cursorItem?.name == "two.md", "Insert moves down")
                self.c.left.mark(mask: "*.md", on: true)
                self.check(self.c.left.marked == ["one.txt", "two.md"], "select group by mask")
                self.c.invertSelection(nil)
                self.check(self.c.left.marked == ["big.bin"], "invert selection (files only)")
                self.c.left.markAll(false)
                self.key(48, "\t") // tab
                self.check(self.c.active === self.c.right, "Tab switches panel")
                self.key(48, "\t")
                self.c.newTab(nil)
                self.check(self.c.left.tabs.count == 2, "new tab")
                self.c.closeTab(nil)
                self.check(self.c.left.tabs.count == 1, "close tab")
            }),
            ("shift marking", {
                let down = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
                let up = String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!))
                let p: FilePanel = self.c.left
                self.c.window?.makeFirstResponder(p.tableView)
                p.markAll(false)
                p.select(name: "big.bin")
                self.key(125, down, .shift)
                self.key(125, down, .shift)
                p.endShiftGesture()
                self.check(p.marked == ["big.bin", "one.txt"], "Shift+Down marks: \(p.marked.sorted())")
                self.key(126, up)
                self.key(126, up)
                self.check(p.cursorItem?.name == "big.bin", "cursor back on marked file")
                self.key(125, down, .shift)
                self.key(125, down, .shift)
                p.endShiftGesture()
                self.check(p.marked.isEmpty, "Shift+Down starting on a marked file unmarks: \(p.marked.sorted())")
                p.select(name: "big.bin")
                p.markRange(from: 2, to: 4)
                self.check(p.marked == ["big.bin", "one.txt", "two.md"], "Shift+click marks range")
                p.markRange(from: 4, to: 3)
                self.check(p.marked == ["big.bin"], "Shift+click on marked file unmarks range: \(p.marked.sorted())")
                p.markAll(false)
            }),
            ("tab state", {
                let p: FilePanel = self.c.left
                p.setMarked(["one.txt", "two.md"])
                p.select(name: "two.md")
                p.switchTab(p.activeTab)
                self.check(p.marked == ["one.txt", "two.md"] && p.cursorItem?.name == "two.md",
                           "re-selecting the current tab keeps marks and cursor")
                p.newTab(url: self.root.appendingPathComponent("b"))
                p.newTab(url: self.root)
                self.check(p.marked.isEmpty, "new tab starts without marks")
                p.switchTab(0)
                self.check(p.marked == ["one.txt", "two.md"] && p.cursorItem?.name == "two.md",
                           "switching back restores marks and cursor: \(p.marked.sorted()) \(p.cursorItem?.name ?? "-")")
                p.closeTab(at: 2)
                self.check(p.activeTab == 0 && p.marked == ["one.txt", "two.md"], "closing a background tab keeps marks")
                p.closeTab(at: 1)
                self.check(p.tabs.count == 1, "tabs closed")
                p.markAll(false)
            }),
            ("settings", {
                let p: FilePanel = self.c.left
                Settings.sizeFormat = .kilobytes
                self.check(Fmt.size(2048) == "2 k", "size format setting")
                Settings.sizeFormat = .bytes
                Settings.typingAction = .commandLine
                self.c.window?.makeFirstResponder(p.tableView)
                self.key(37, "l")
                self.key(1, "s")
                self.check(self.c.commandLineText == "ls", "typing goes to the command line: '\(self.c.commandLineText)'")
                self.key(51, "\u{7f}")
                self.check(self.c.commandLineText == "l" && p.currentURL.lastPathComponent == "a",
                           "Backspace edits the command line instead of going up")
                self.c.clearCommandLine()
                self.key(31, "ø", .option, ignoring: "o") // ⌥O
                self.check(p.cursorItem?.name == "one.txt", "⌥+letter quick search in command-line mode")
                self.key(53, "\u{1b}")
                Settings.typingAction = .quickSearch
                Settings.foldersFirst = false
                self.check(p.items.map(\.name).firstIndex(of: "big.bin")! < p.items.map(\.name).firstIndex(of: "sub")!,
                           "folders mixed with files when 'folders first' is off")
                Settings.foldersFirst = true
                self.check(p.items[1].name == "sub", "folders first again")
            }),
            ("thumbnails", {
                let p: FilePanel = self.c.left
                let gallery = self.root.appendingPathComponent("gallery")
                try? fm.createDirectory(at: gallery, withIntermediateDirectories: true)
                let colors: [NSColor] = [.systemRed, .systemOrange, .systemGreen, .systemBlue, .systemPurple, .systemTeal, .systemPink]
                for (i, color) in colors.enumerated() {
                    let img = NSImage(size: NSSize(width: 400, height: 300), flipped: false) { r in
                        NSGradient(starting: color, ending: color.blended(withFraction: 0.6, of: .black)!)!.draw(in: r, angle: -60)
                        let text = NSAttributedString(string: "Photo \(i + 1)", attributes: [.font: NSFont.boldSystemFont(ofSize: 48),
                                                                                         .foregroundColor: NSColor.white])
                        text.draw(at: NSPoint(x: 30, y: 30))
                        return true
                    }
                    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
                    try? rep.representation(using: .png, properties: [:])!.write(to: gallery.appendingPathComponent("photo-\(i + 1).png"))
                }
                try? "Some notes for the quick view test.".write(to: gallery.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
                p.navigate(to: gallery)
                p.setViewMode(.thumbnails)
                p.activate()
                self.check(p.focusView === p.grid && self.c.window?.firstResponder === p.grid, "thumbnail grid takes focus")
                self.check(p.grid.numberOfItems(inSection: 0) == p.items.count, "grid shows all items (\(p.items.count))")
                p.setCursor(1)
                self.check(p.grid.selectionIndexPaths.first?.item == 1, "grid mirrors the cursor")
                let right = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))
                let down = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
                func gridKey(_ code: UInt16, _ chars: String) {
                    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: self.c.window?.windowNumber ?? 0, context: nil, characters: chars,
                                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                    p.grid.keyDown(with: e)
                }
                gridKey(124, right)
                self.check(p.tableView.selectedRow == 2, "→ moves to the next tile")
                let cols = p.grid.columns
                gridKey(125, down)
                self.check(p.tableView.selectedRow == min(2 + cols, p.items.count - 1), "↓ moves one row (\(cols) columns)")
                p.setCursor(1)
                gridKey(49, " ")
                self.check(p.marked == [p.items[1].name], "Space marks in thumbnail view")
                p.markAll(false)
                p.select(name: "photo-2.png")
            }),
            ("wait", {}),
            ("quick view", {
                let p: FilePanel = self.c.left
                self.c.toggleQuickView(nil)
                let r: FilePanel = self.c.right
                self.check(r.isQuickView, "Quick View opens in the other panel")
                p.select(name: "notes.txt")
            }),
            ("wait", {}),
            ("quick view follows", {
                let r: FilePanel = self.c.right
                self.check(r.pathHeader.stringValue.contains("notes.txt"), "Quick View follows the cursor: \(r.pathHeader.stringValue)")
                if ProcessInfo.processInfo.environment["FA_KEEP"] != nil { return }
                self.c.switchPanel()
                self.check(!r.isQuickView, "moving into the Quick View panel closes it")
                self.c.left.activate()
                self.c.left.setViewMode(.details)
                self.check(self.c.left.focusView === self.c.left.tableView, "back to details view")
                self.c.left.navigate(to: self.root.appendingPathComponent("a"))
            }),
            ("undo: copy", {
                let u = self.root.appendingPathComponent("undo")
                try? fm.removeItem(at: u)
                try! fm.createDirectory(at: u.appendingPathComponent("dst"), withIntermediateDirectories: true)
                try! "u".write(to: u.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
                self.c.left.navigate(to: u)
                self.c.performTransfer([u.appendingPathComponent("file.txt")], to: u.appendingPathComponent("dst"), move: false)
            }),
            ("wait", {}),
            ("undo: copy check", {
                let u = self.root.appendingPathComponent("undo")
                let copy = u.appendingPathComponent("dst/file.txt")
                self.check(fm.fileExists(atPath: copy.path) && self.c.fileUndo.canUndo
                           && self.c.fileUndo.undoActionName == "Copy", "copy registers Undo Copy")
                self.c.fileUndo.undo()
                self.check(!fm.fileExists(atPath: copy.path) && fm.fileExists(atPath: u.appendingPathComponent("file.txt").path),
                           "Undo Copy moves the copy to the Trash, original untouched")
                self.c.fileUndo.redo()
                self.check(fm.fileExists(atPath: copy.path), "Redo puts the copy back")
                try? fm.removeItem(at: copy)
                self.c.fileUndo.removeAllActions()
                self.c.performTransfer([u.appendingPathComponent("file.txt")], to: u.appendingPathComponent("dst"), move: true)
            }),
            ("wait", {}),
            ("undo: move check", {
                let u = self.root.appendingPathComponent("undo")
                self.check(fm.fileExists(atPath: u.appendingPathComponent("dst/file.txt").path)
                           && self.c.fileUndo.undoActionName == "Move", "move registers Undo Move")
                self.c.fileUndo.undo()
                self.check(fm.fileExists(atPath: u.appendingPathComponent("file.txt").path)
                           && !fm.fileExists(atPath: u.appendingPathComponent("dst/file.txt").path), "Undo Move puts the file back")
                Settings.confirmDelete = false
                self.c.left.reload(selectName: "file.txt")
                self.c.left.select(name: "file.txt")
                self.c.deleteFiles(permanent: false)
            }),
            ("wait", {}),
            ("undo: trash check", {
                let u = self.root.appendingPathComponent("undo")
                Settings.confirmDelete = true
                self.check(!fm.fileExists(atPath: u.appendingPathComponent("file.txt").path)
                           && self.c.fileUndo.undoActionName == "Move to Trash", "trash registers Undo")
                self.c.fileUndo.undo()
                self.check((try? String(contentsOf: u.appendingPathComponent("file.txt"), encoding: .utf8)) == "u",
                           "Undo Move to Trash restores the file")
                self.c.fileUndo.removeAllActions()
                let job = TransferJob(sources: [u.appendingPathComponent("file.txt")], destDir: u.appendingPathComponent("bg"),
                                      newName: nil, move: false)
                job.start(on: self.c.window, background: true) { self.backgroundDone = true }
                self.check(BackgroundQueue.shared.entries.count == 1, "job queued in the background")
            }),
            ("wait", {}),
            ("background check", {
                let u = self.root.appendingPathComponent("undo")
                self.check(self.backgroundDone && fm.fileExists(atPath: u.appendingPathComponent("bg/file.txt").path)
                           && BackgroundQueue.shared.entries.isEmpty, "background copy finished and left the queue")
                self.c.left.navigate(to: self.root.appendingPathComponent("a"))
            }),
            ("sync", {
                let base = self.root.appendingPathComponent("sync")
                try? fm.removeItem(at: base)
                let l = base.appendingPathComponent("L"), r = base.appendingPathComponent("R")
                for d in [l.appendingPathComponent("sub"), r.appendingPathComponent("sub"), l.appendingPathComponent("onlyL")] {
                    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
                }
                func write(_ u: URL, _ text: String, _ age: TimeInterval) {
                    try! text.write(to: u, atomically: true, encoding: .utf8)
                    try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path)
                }
                write(l.appendingPathComponent("same.txt"), "same", 1000)
                write(r.appendingPathComponent("same.txt"), "same", 1000)
                write(l.appendingPathComponent("sub/newer-left.txt"), "new", 10)
                write(r.appendingPathComponent("sub/newer-left.txt"), "old", 5000)
                write(r.appendingPathComponent("only-right.txt"), "r", 100)
                write(l.appendingPathComponent("onlyL/inner.txt"), "i", 100)
                write(l.appendingPathComponent("conflict.txt"), "aaaa", 1000)
                write(r.appendingPathComponent("conflict.txt"), "bb", 1000)
                let items = try! FolderSync.compare(l, r, options: FolderSync.Options(), cancel: CancelFlag())
                func find(_ p: String) -> SyncItem? { items.first { $0.path == p } }
                self.check(find("same.txt")?.state == .equal, "sync: equal files detected")
                self.check(find("sub/newer-left.txt")?.action == .leftToRight, "sync: newer left copies right")
                self.check(find("only-right.txt")?.action == .rightToLeft, "sync: right-only copies left")
                self.check(find("onlyL")?.isDirectory == true && find("onlyL/inner.txt") == nil, "sync: one-sided folder is one row")
                self.check(find("conflict.txt")?.state == .differ && find("conflict.txt")?.action == FolderSync.defaultAction(.differ, FolderSync.Options()),
                           "sync: same date, different size is a conflict")
                var mirror = FolderSync.Options()
                mirror.direction = .leftToRight
                mirror.deleteExtras = true
                let m = try! FolderSync.compare(l, r, options: mirror, cancel: CancelFlag())
                self.check(m.first { $0.path == "only-right.txt" }?.action == .deleteRight, "sync: mirror deletes extras on the target")
                // A folder on one side and a file on the other is never resolved automatically.
                let t = base.appendingPathComponent("T")
                try! fm.createDirectory(at: t.appendingPathComponent("L/thing"), withIntermediateDirectories: true)
                try! fm.createDirectory(at: t.appendingPathComponent("R"), withIntermediateDirectories: true)
                write(t.appendingPathComponent("R/thing"), "file", 100)
                let typeConflict = try! FolderSync.compare(t.appendingPathComponent("L"), t.appendingPathComponent("R"), options: mirror,
                                                           cancel: CancelFlag())
                self.check(typeConflict.first?.isTypeConflict == true && typeConflict.first?.action == SyncItem.Action.none,
                           "sync: folder-vs-file conflict gets no action even in mirror mode")
                // An unreadable folder must abort the comparison instead of looking empty (mirror mode would
                // otherwise delete everything on the other side).
                if geteuid() != 0 {
                    let u = base.appendingPathComponent("U")
                    try! fm.createDirectory(at: u.appendingPathComponent("L/locked"), withIntermediateDirectories: true)
                    try! fm.createDirectory(at: u.appendingPathComponent("R/locked"), withIntermediateDirectories: true)
                    write(u.appendingPathComponent("R/locked/keep.txt"), "keep", 100)
                    chmod(u.appendingPathComponent("L/locked").path, 0)
                    let aborted = (try? FolderSync.compare(u.appendingPathComponent("L"), u.appendingPathComponent("R"), options: mirror,
                                                           cancel: CancelFlag())) == nil
                    chmod(u.appendingPathComponent("L/locked").path, 0o755)
                    self.check(aborted, "sync: unreadable folder aborts the comparison")
                }
                let job = SyncJob(items: items, left: l, right: r)
                job.start(on: self.c.window) {}
            }),
            ("wait", {}),
            ("sync check", {
                let base = self.root.appendingPathComponent("sync")
                let l = base.appendingPathComponent("L"), r = base.appendingPathComponent("R")
                self.check((try? String(contentsOf: r.appendingPathComponent("sub/newer-left.txt"), encoding: .utf8)) == "new"
                           && fm.fileExists(atPath: l.appendingPathComponent("only-right.txt").path)
                           && fm.fileExists(atPath: r.appendingPathComponent("onlyL/inner.txt").path), "sync: synchronized both ways")
                self.check((try? String(contentsOf: r.appendingPathComponent("conflict.txt"), encoding: .utf8)) == "bb",
                           "sync: conflict left untouched")
                let again = try! FolderSync.compare(l, r, options: FolderSync.Options(), cancel: CancelFlag())
                self.check(again.filter { $0.state != .equal }.map(\.path) == ["conflict.txt"], "sync: only the conflict remains")
            }),
            ("diff", {
                let rows = TextDiff.rows(["a", "b", "c", "d"], ["a", "B", "c", "x", "d", "e"])
                self.check(rows.map(\.kind) == [.equal, .changed, .equal, .added, .equal, .added], "diff rows: \(rows.map(\.kind))")
                let ws = TextDiff.rows(["a  b"], ["a b"], ignoreWhitespace: true)
                self.check(ws.map(\.kind) == [.equal], "diff ignores whitespace when asked")
                let d = self.root.appendingPathComponent("diffbin")
                try? fm.createDirectory(at: d, withIntermediateDirectories: true)
                try! Data([1, 0, 2, 3]).write(to: d.appendingPathComponent("x.bin"))
                try! Data([1, 0, 2, 4]).write(to: d.appendingPathComponent("y.bin"))
                self.check(TextDiff.isBinary(d.appendingPathComponent("x.bin"))
                           && (try! TextDiff.firstDifference(d.appendingPathComponent("x.bin"), d.appendingPathComponent("y.bin"))) == 3,
                           "binary compare finds first differing byte")
                self.check((try! TextDiff.firstDifference(d.appendingPathComponent("x.bin"), d.appendingPathComponent("x.bin"))) == nil,
                           "identical binary files")
                var unreadableThrew = false
                do { _ = try TextDiff.firstDifference(d.appendingPathComponent("x.bin"), d.appendingPathComponent("missing.bin")) }
                catch { unreadableThrew = true }
                self.check(unreadableThrew, "binary compare reports an unreadable file as an error, not as a difference at byte 0")
            }),
            ("finder tags", {
                let d = self.root.appendingPathComponent("tags")
                try? fm.removeItem(at: d)
                try! fm.createDirectory(at: d, withIntermediateDirectories: true)
                for n in ["red.txt", "both.txt", "none.txt"] {
                    try! n.write(to: d.appendingPathComponent(n), atomically: true, encoding: .utf8)
                }
                let red = FinderTags.standard[0], blue = FinderTags.standard[4]
                try? FinderTags.write(d.appendingPathComponent("red.txt"), [red])
                try? FinderTags.write(d.appendingPathComponent("both.txt"), [red, FinderTag(name: "Project X", colorIndex: 0)])
                let read = FinderTags.read(d.appendingPathComponent("both.txt").path)
                self.check(read.map(\.name) == [red.name, "Project X"] && read.first?.colorIndex == 6,
                           "tags written via macOS are read back with colors: \(read)")
                let p: FilePanel = self.c.left
                p.navigate(to: d)
                self.c.window?.makeFirstResponder(p.tableView)
                self.check(p.items.first { $0.name == "red.txt" }?.tags.first?.color == .systemRed, "panel items carry their tags")
                p.setMarked(["red.txt", "none.txt"])
                self.c.toggleStandardTag(4) // blue on both
                let afterBlue = FinderTags.read(d.appendingPathComponent("none.txt").path)
                self.check(afterBlue.contains { $0.name == blue.name }, "toggle adds a color tag to all selected files")
                p.setMarked(["red.txt", "none.txt"])
                self.c.toggleStandardTag(4) // all have blue -> removed from all
                self.check(!FinderTags.read(d.appendingPathComponent("red.txt").path).contains { $0.name == blue.name },
                           "toggle removes a tag when all selected files have it")
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.representedObject = red.name
                self.c.selectByTag(item)
                self.check(p.marked == ["red.txt", "both.txt"], "Select by Tag marks tagged files: \(p.marked.sorted())")
                p.markAll(false)
                p.navigate(to: self.root.appendingPathComponent("a"))
            }),
            ("path bar", {
                let p: FilePanel = self.c.left
                let sub = self.root.appendingPathComponent("a/sub")
                p.navigate(to: sub)
                self.c.window?.layoutIfNeeded()
                let h = p.pathHeader
                // Click the "a" segment (second to last).
                let comps = p.currentURL.path.split(separator: "/").count
                guard let x = h.centerX(ofSegment: comps - 1) else {
                    self.check(false, "path bar: segment for 'a' not found in \(h.stringValue)")
                    return
                }
                let pt = h.convert(NSPoint(x: x, y: h.bounds.midY), to: nil)
                let e = NSEvent.mouseEvent(with: .leftMouseDown, location: pt, modifierFlags: [], timestamp: 0,
                                           windowNumber: self.c.window!.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1)!
                h.mouseDown(with: e)
                self.check(p.currentURL.lastPathComponent == "a" && p.cursorItem?.name == "sub",
                           "path bar: clicking a folder in the path goes there (\(p.currentURL.lastPathComponent), cursor \(p.cursorItem?.name ?? "-"))")
            }),
            ("folder tree", {
                let p: FilePanel = self.c.left
                let a = self.root.appendingPathComponent("a")
                p.navigate(to: a)
                p.setViewMode(.tree)
                p.activate()
                self.check(p.focusView === p.tree && p.tree.selectedFolder?.path == FolderTreeView.realURL(p.currentURL).path,
                           "tree opens at the current folder: \(p.tree.selectedFolder?.path ?? "-")")
                func treeKey(_ code: UInt16, _ chars: String) {
                    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: self.c.window?.windowNumber ?? 0, context: nil, characters: chars,
                                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                    p.tree.keyDown(with: e)
                }
                let row = p.tree.selectedRow
                p.tree.expandItem(p.tree.item(atRow: row))
                p.tree.selectRowIndexes([row + 1], byExtendingSelection: false)
                let target = p.tree.selectedFolder?.lastPathComponent
                treeKey(36, "\r")
                self.check(p.viewMode == .details && p.currentURL.lastPathComponent == target,
                           "Enter in the tree opens the folder (\(target ?? "-")) and returns to the list")
                p.setViewMode(.tree)
                treeKey(53, "\u{1b}")
                self.check(p.viewMode == .details && p.currentURL.lastPathComponent == target, "Esc leaves the tree without navigating")
                p.navigate(to: a)
                p.activate()
            }),
            ("spotlight", {
                // Spotlight only indexes some locations; the user's home is indexed, the scratch folder may not be.
                // Check that the query runs and that results are filtered to the root with the mask applied.
                let home = FileManager.default.homeDirectoryForCurrentUser
                let found = SearchWindowController.spotlight(root: home, maskText: "*.txt|*.log", needle: "", caseSensitive: false,
                                                             subdirs: false, hidden: false, packages: false, cancel: CancelFlag())
                self.check(found.allSatisfy { $0.pathExtension.lowercased() == "txt"
                                              && $0.deletingLastPathComponent().standardizedFileURL == home.standardizedFileURL },
                           "Spotlight results filtered by mask and folder (\(found.count) found)")
            }),
            ("duplicates and usage", {
                let d = self.root.appendingPathComponent("dups")
                try? fm.removeItem(at: d)
                try! fm.createDirectory(at: d.appendingPathComponent("deep"), withIntermediateDirectories: true)
                let content = Data(repeating: 42, count: 200_000)
                try! content.write(to: d.appendingPathComponent("one.bin"))
                try! content.write(to: d.appendingPathComponent("deep/two.bin"))
                var different = content
                different[150_000] = 1 // same size and same first 64 KB, different later
                try! different.write(to: d.appendingPathComponent("three.bin"))
                try! Data(repeating: 1, count: 10).write(to: d.appendingPathComponent("tiny.txt"))
                // A hard link is the same file, not a duplicate: it must never be offered for deletion.
                link(d.appendingPathComponent("one.bin").path, d.appendingPathComponent("hard.bin").path)
                let groups = DuplicateFinder.find(in: d, subfolders: true, hidden: false, minSize: 1, cancel: CancelFlag())
                let names = Set(groups.first?.files.map(\.name) ?? [])
                self.check(groups.count == 1 && names.count == 2 && names.contains("two.bin")
                           && !(names.contains("one.bin") && names.contains("hard.bin")),
                           "duplicates: identical files grouped, hard link counted once (\(groups.map { $0.files.map(\.name) }))")
                let tree = UsageNode.scan(d, hidden: false, cancel: CancelFlag())
                // 4 × 200,000 (the hard link counts as a file, like Finder does) + tiny.txt
                self.check(tree.size == 800_010 && tree.children.first?.size == 200_000, "usage: sizes add up (\(tree.size))")
                let rects = Treemap.layout([6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 600, height: 400))
                let area = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
                self.check(abs(area - 240_000) < 1 && rects.allSatisfy { CGRect(x: 0, y: 0, width: 600, height: 400).insetBy(dx: -0.01, dy: -0.01).contains($0) },
                           "treemap fills the area exactly")
            }),
            ("async listing", {
                // Force the asynchronous path (normally taken only by slow folders) and check the hand-off.
                let p: FilePanel = self.c.left
                let many = self.root.appendingPathComponent("many")
                try? fm.createDirectory(at: many, withIntermediateDirectories: true)
                for i in 0..<300 { fm.createFile(atPath: many.appendingPathComponent("f\(i).txt").path, contents: nil) }
                FilePanel.synchronousListingTimeout = 0
                p.navigate(to: many, select: "f42.txt")
                self.check(p.items.isEmpty && p.pathHeader.stringValue.contains("loading"),
                           "async listing: slow folder shows the loading state instead of blocking")
            }),
            ("wait", {}),
            ("async listing check", {
                let p: FilePanel = self.c.left
                self.check(p.items.count == 301 && p.cursorItem?.name == "f42.txt" && !p.pathHeader.stringValue.contains("loading"),
                           "async listing: items arrive later with the cursor where asked (\(p.items.count), \(p.cursorItem?.name ?? "-"))")
                p.setMarked(["f1.txt", "f2.txt"])
                p.reload()
                self.check(p.items.count == 301 && p.marked == ["f1.txt", "f2.txt"],
                           "async listing: refreshing keeps the old list and marks while loading")
            }),
            ("wait", {}),
            ("async listing marks", {
                let p: FilePanel = self.c.left
                self.check(p.items.count == 301 && p.marked == ["f1.txt", "f2.txt"], "async listing: marks survive the refresh")
                p.newTab(url: self.root)
                p.switchTab(0)
            }),
            ("wait", {}),
            ("async listing tabs", {
                let p: FilePanel = self.c.left
                self.check(p.marked == ["f1.txt", "f2.txt"], "async listing: tab marks restored after the listing arrives")
                p.closeTab(at: 1)
                p.markAll(false)
                FilePanel.synchronousListingTimeout = 0.15
                p.navigate(to: self.root.appendingPathComponent("a"))
                self.check(!p.items.isEmpty, "sync listing: fast path is back")
            }),
            ("long folder name", {
                let long = String(repeating: "very-long-folder-name-", count: 12)
                let dir = a.appendingPathComponent(long)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                self.c.window?.layoutIfNeeded()
                let before = (self.c.left.frame.width, self.c.right.frame.width)
                self.c.left.navigate(to: dir)
                self.c.left.newTab(url: dir)
                self.c.right.navigate(to: dir)
                self.c.window?.layoutIfNeeded()
                self.widthsBefore = before
            }),
            ("long folder name check", {
                let a = self.root.appendingPathComponent("a"), b = self.root.appendingPathComponent("b")
                let dir = a.appendingPathComponent(String(repeating: "very-long-folder-name-", count: 12))
                let before = self.widthsBefore
                let after = (self.c.left.frame.width, self.c.right.frame.width)
                self.check(abs(before.0 - after.0) < 1 && abs(before.1 - after.1) < 1,
                           "long path keeps panel widths \(before) → \(after)")
                self.c.left.closeTab()
                self.c.left.navigate(to: a)
                self.c.right.navigate(to: b)
                try? fm.removeItem(at: dir)
            }),
            ("copy", {
                self.c.left.mark(mask: "*.txt;*.md", on: true)
                self.c.left.mark(mask: "sub/", on: true)
                self.c.performTransfer(self.c.left.operationItems.map(\.url), to: b, move: false)
            }),
            ("wait", {}),
            ("verify copy", {
                self.check(fm.fileExists(atPath: b.appendingPathComponent("sub/three.txt").path), "recursive copy")
                self.check((try? String(contentsOf: b.appendingPathComponent("one.txt"), encoding: .utf8)) == "hello", "copied content")
                self.check(fm.fileExists(atPath: a.appendingPathComponent("one.txt").path), "source kept after copy")
                self.c.right.reload()
                self.check(Set(self.names(self.c.right)) == ["..", "sub", "one.txt", "two.md"], "right panel refreshed")
                self.c.left.markAll(false)
                self.c.left.select(name: "big.bin")
                self.c.performTransfer([a.appendingPathComponent("big.bin")], to: b, move: true)
            }),
            ("wait", {}),
            ("verify move", {
                self.check(!fm.fileExists(atPath: a.appendingPathComponent("big.bin").path), "move removes source")
                let size = (try? fm.attributesOfItem(atPath: b.appendingPathComponent("big.bin").path)[.size] as? Int) ?? 0
                self.check(size == 5_000_000, "moved file intact (\(size) bytes)")
                self.c.window?.makeFirstResponder(self.c.right.tableView)
                self.c.right.reload()
                self.c.right.mark(mask: "*.txt;*.md", on: true)
                self.c.packFilesTo(b.appendingPathComponent("arch.zip"))
            }),
            ("wait", {}),
            ("verify pack", {
                self.check(fm.fileExists(atPath: b.appendingPathComponent("arch.zip").path), "zip created")
                let out = self.root.appendingPathComponent("x")
                try? fm.createDirectory(at: out, withIntermediateDirectories: true)
                self.c.extract([b.appendingPathComponent("arch.zip")], to: out, members: [])
            }),
            ("wait", {}),
            ("verify unpack", {
                let out = self.root.appendingPathComponent("x")
                self.check((try? String(contentsOf: out.appendingPathComponent("two.md"), encoding: .utf8)) == "world", "unzip")
                self.c.right.reload()
                self.c.right.calculateSize(of: self.c.right.items.first { $0.name == "sub" }!)
            }),
            ("wait", {}),
            ("verify size", {
                self.check(self.c.right.items.first { $0.name == "sub" }?.dirSize == 4, "folder size calculated")
                let job = DeleteJob(urls: [b.appendingPathComponent("sub")], permanent: true)
                job.start(on: self.c.window) {}
            }),
            ("wait", {}),
            ("data safety", {
                FileJob.testErrors = []
                let d = self.root.appendingPathComponent("safety")
                try? fm.removeItem(at: d)
                try! fm.createDirectory(at: d.appendingPathComponent("Foo/inner"), withIntermediateDirectories: true)
                try! "x".write(to: d.appendingPathComponent("Foo/inner/f.txt"), atomically: true, encoding: .utf8)
                // Copying Foo into foo/ (same folder on a case-insensitive volume) must be refused, not recurse.
                self.c.performTransfer([d.appendingPathComponent("Foo")], to: d.appendingPathComponent("foo/Foo/sub"), move: false)
            }),
            ("wait", {}),
            ("verify folder into itself", {
                let d = self.root.appendingPathComponent("safety")
                self.check(FileJob.testErrors?.contains { $0.contains("into itself") } == true,
                           "copy into itself via different case is refused: \(FileJob.testErrors ?? [])")
                self.check(!fm.fileExists(atPath: d.appendingPathComponent("Foo/sub/Foo/inner").path), "no runaway recursion")
                FileJob.testErrors = []
                // Pack must not treat a file named "-m" as an option (zip -m would delete the files).
                try! "keep".write(to: d.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
                try! "m".write(to: d.appendingPathComponent("-m"), atomically: true, encoding: .utf8)
                let p: FilePanel = self.c.left
                p.navigate(to: d)
                self.c.window?.makeFirstResponder(p.tableView)
                p.setMarked(["keep.txt", "-m"])
                self.c.packFilesTo(d.appendingPathComponent("out.zip"))
            }),
            ("wait", {}),
            ("verify pack dash names", {
                let d = self.root.appendingPathComponent("safety")
                self.check(fm.fileExists(atPath: d.appendingPathComponent("keep.txt").path)
                           && fm.fileExists(atPath: d.appendingPathComponent("-m").path), "pack keeps the source files")
                self.check(fm.fileExists(atPath: d.appendingPathComponent("out.zip").path), "zip with '-m' member created")
                // Unpack over an existing file: goes through staging and the overwrite question (answered: skip).
                try! "IMPORTANT".write(to: d.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)
                let src = d.appendingPathComponent("src")
                try! fm.createDirectory(at: src, withIntermediateDirectories: true)
                try! "from archive".write(to: src.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)
                try! "new".write(to: src.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
                let zip = Process()
                zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                zip.arguments = ["-q", d.appendingPathComponent("conflict.zip").path, "existing.txt", "new.txt"]
                zip.currentDirectoryURL = src
                try! zip.run()
                zip.waitUntilExit()
                FileJob.testOverwrite = false
                self.c.extract([d.appendingPathComponent("conflict.zip")], to: d, members: [])
            }),
            ("wait", {}),
            ("verify unpack", {
                let d = self.root.appendingPathComponent("safety")
                FileJob.testOverwrite = true
                self.check((try? String(contentsOf: d.appendingPathComponent("existing.txt"), encoding: .utf8)) == "IMPORTANT",
                           "unpack does not silently overwrite existing files")
                self.check(fm.fileExists(atPath: d.appendingPathComponent("new.txt").path), "unpack adds new files")
                let leftovers = ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasPrefix(".fileadmiral-unpack") }
                self.check(leftovers.isEmpty, "unpack staging folder removed")
                // Copying a FIFO must not hang.
                let fifo = d.appendingPathComponent("pipe")
                mkfifo(fifo.path, 0o644)
                // Move with a mask: only matching files are removed from the source.
                let m = d.appendingPathComponent("maskmove")
                try! fm.createDirectory(at: m.appendingPathComponent("in"), withIntermediateDirectories: true)
                try! "a".write(to: m.appendingPathComponent("in/a.txt"), atomically: true, encoding: .utf8)
                try! "b".write(to: m.appendingPathComponent("in/b.md"), atomically: true, encoding: .utf8)
                let job = TransferJob(sources: [m.appendingPathComponent("in")], destDir: m.appendingPathComponent("out"),
                                      newName: nil, move: true, mask: FileMask("*.txt"))
                job.start(on: self.c.window) {}
                let job2 = TransferJob(sources: [fifo], destDir: m, newName: nil, move: false)
                job2.start(on: self.c.window) {}
            }),
            ("wait", {}),
            ("verify mask move", {
                let m = self.root.appendingPathComponent("safety/maskmove")
                self.check(fm.fileExists(atPath: m.appendingPathComponent("out/in/a.txt").path)
                           && !fm.fileExists(atPath: m.appendingPathComponent("in/a.txt").path), "mask move moves matching file")
                self.check(fm.fileExists(atPath: m.appendingPathComponent("in/b.md").path)
                           && !fm.fileExists(atPath: m.appendingPathComponent("out/in/b.md").path), "mask move leaves other files")
                self.check(FileJob.testErrors?.contains { $0.contains("special file") } == true, "FIFO skipped without hanging")
                // Multi-rename: swap two names through temporary names.
                let r = self.root.appendingPathComponent("safety/ren")
                try! fm.createDirectory(at: r, withIntermediateDirectories: true)
                try! "1".write(to: r.appendingPathComponent("a"), atomically: true, encoding: .utf8)
                try! "2".write(to: r.appendingPathComponent("b"), atomically: true, encoding: .utf8)
                let res = MultiRenameWindowController.apply([(r.appendingPathComponent("a"), r.appendingPathComponent("b")),
                                                             (r.appendingPathComponent("b"), r.appendingPathComponent("a"))])
                self.check(res.errors.isEmpty && (try? String(contentsOf: r.appendingPathComponent("a"), encoding: .utf8)) == "2",
                           "multi-rename swaps names safely")
                FileJob.testErrors = nil
                self.c.left.navigate(to: self.root.appendingPathComponent("a"))
            }),
            ("plugins", {
                let pm = PluginManager.shared
                try? fm.removeItem(at: pm.folder)
                let installed = pm.installSamples()
                self.check(installed.count == 6 && pm.plugins.count == 6 && pm.errors.isEmpty,
                           "sample plugins install and load: \(installed) \(pm.errors)")
                self.check(pm.commandPlugins.count == 4 && pm.viewerPlugins(for: URL(fileURLWithPath: "/x/a.png")).count == 2,
                           "command and viewer plugins classified")
                if let meta = pm.plugins.first(where: { $0.id == "file-metadata" }) {
                    pm.render(meta, file: self.root.appendingPathComponent("a/one.txt")) { self.pluginOutput = $0 }
                }
                self.check(PluginManager.parseShortcut("cmd+shift+p")?.1 == [.command, .shift]
                           && PluginManager.parseShortcut("ctrl+alt+f5")?.0 == fkey(5), "shortcut parsing")
            }),
            ("wait", {}),
            ("wait", {}),
            ("wait", {}),
            ("verify plugins", {
                self.check(self.pluginOutput.contains("kMDItem"), "viewer plugin output: \(self.pluginOutput.prefix(60))")
            }),
            ("remote file systems", {
                let env = ProcessInfo.processInfo.environment
                guard let key = env["FA_TEST_SSH_KEY"], let ftpRoot = env["FA_TEST_FTP_ROOT"] else {
                    print("SKIP: remote tests (FA_TEST_SSH_KEY / FA_TEST_FTP_ROOT not set)")
                    return
                }
                let local = self.root.appendingPathComponent("remote-local")
                try? fm.removeItem(at: local)
                try! fm.createDirectory(at: local.appendingPathComponent("up/inner"), withIntermediateDirectories: true)
                try! "upload me".write(to: local.appendingPathComponent("up/inner/f.txt"), atomically: true, encoding: .utf8)
                try! "single".write(to: local.appendingPathComponent("one file.txt"), atomically: true, encoding: .utf8)
                let sftpDir = self.root.appendingPathComponent("sftp-area").path
                try? fm.removeItem(atPath: sftpDir)
                try! fm.createDirectory(atPath: sftpDir, withIntermediateDirectories: true)
                self.remoteResults = []
                DispatchQueue.global().async {
                    var results: [(Bool, String)] = []
                    func exercise(_ fs: RemoteFileSystem, _ base: String, _ label: String) {
                        do {
                            try fs.upload(local.appendingPathComponent("up"), to: RemotePath.join(base, "up"))
                            try fs.upload(local.appendingPathComponent("one file.txt"), to: RemotePath.join(base, "one file.txt"))
                            let names = Set(try fs.list(base).map(\.name))
                            results.append((names.isSuperset(of: ["up", "one file.txt"]), "\(label): upload + list \(names.sorted())"))
                            let inner = try fs.list(RemotePath.join(base, "up/inner"))
                            results.append((inner.first?.name == "f.txt" && inner.first?.size == 9, "\(label): recursive upload, sizes"))
                            try fs.makeDirectory(RemotePath.join(base, "made"))
                            try fs.rename(RemotePath.join(base, "one file.txt"), to: RemotePath.join(base, "made/renamed.txt"))
                            let dl = local.appendingPathComponent("dl-\(label)")
                            try fs.download(RemotePath.join(base, "up"), isDirectory: true, to: dl)
                            let text = try? String(contentsOf: dl.appendingPathComponent("inner/f.txt"), encoding: .utf8)
                            results.append((text == "upload me", "\(label): recursive download"))
                            try fs.download(RemotePath.join(base, "made/renamed.txt"), isDirectory: false,
                                            to: local.appendingPathComponent("\(label)-renamed.txt"))
                            results.append((fm.fileExists(atPath: local.appendingPathComponent("\(label)-renamed.txt").path),
                                            "\(label): mkdir, rename, file download"))
                            try fs.delete(RemotePath.join(base, "up"), isDirectory: true)
                            try fs.delete(RemotePath.join(base, "made/renamed.txt"), isDirectory: false)
                            let after = Set(try fs.list(base).map(\.name))
                            let madeEmpty = try fs.list(RemotePath.join(base, "made")).isEmpty
                            results.append((!after.contains("up") && madeEmpty,
                                            "\(label): recursive delete \(after.sorted())"))
                        } catch {
                            results.append((false, "\(label): \(error.localizedDescription)"))
                        }
                    }
                    let sftp = SFTPFileSystem(host: "127.0.0.1", port: 2222, user: NSUserName(), password: "secret pass",
                                              keyFile: key, initialPath: nil)
                    do {
                        try sftp.connect()
                        results.append((sftp.initialPath.hasPrefix("/"), "sftp: connect with key passphrase, home \(sftp.initialPath)"))
                        exercise(sftp, sftpDir, "sftp")
                        sftp.close()
                    } catch {
                        results.append((false, "sftp connect: \(error.localizedDescription)"))
                    }
                    let bad = SFTPFileSystem(host: "127.0.0.1", port: 2222, user: NSUserName(), password: "wrong",
                                             keyFile: key, initialPath: nil)
                    do {
                        try bad.connect()
                        results.append((false, "sftp: wrong passphrase must fail"))
                    } catch {
                        results.append((true, "sftp: wrong passphrase rejected (\(error.localizedDescription.prefix(40)))"))
                    }
                    bad.close()
                    let ftp = FTPFileSystem(host: "127.0.0.1", port: 2121, user: "test", password: "test pass", tls: false,
                                            allowInvalidCertificate: false, initialPath: nil)
                    do {
                        try ftp.connect()
                        results.append((ftp.initialPath == "/", "ftp: connect, home \(ftp.initialPath)"))
                        try? fm.removeItem(atPath: ftpRoot + "/area")
                        try fm.createDirectory(atPath: ftpRoot + "/area", withIntermediateDirectories: true)
                        exercise(ftp, "/area", "ftp")
                    } catch {
                        results.append((false, "ftp connect: \(error.localizedDescription)"))
                    }
                    DispatchQueue.main.async { self.remoteResults = results }
                }
            }),
            ("wait", {}), ("wait", {}), ("wait", {}), ("wait", {}), ("wait", {}), ("wait", {}), ("wait", {}), ("wait", {}),
            ("verify remote", {
                guard ProcessInfo.processInfo.environment["FA_TEST_SSH_KEY"] != nil else { return }
                if self.remoteResults.isEmpty { self.check(false, "remote tests did not finish in time") }
                for (ok, what) in self.remoteResults { self.check(ok, what) }
            }),
            ("sftp panel: connect", {
                guard self.remoteEnv else { return }
                FileJob.testErrors = []
                let local = self.root.appendingPathComponent("panel-sftp")
                try? fm.removeItem(at: local)
                try! fm.createDirectory(at: local.appendingPathComponent("folder"), withIntermediateDirectories: true)
                try! "up".write(to: local.appendingPathComponent("upload.txt"), atomically: true, encoding: .utf8)
                try! "in folder".write(to: local.appendingPathComponent("folder/x.txt"), atomically: true, encoding: .utf8)
                self.c.left.navigate(to: local)
                self.c.window?.makeFirstResponder(self.c.right.tableView)
                let c = Connection(name: "t", kind: .sftp, host: "127.0.0.1", port: 2222, user: NSUserName(),
                                   keyFile: ProcessInfo.processInfo.environment["FA_TEST_SSH_KEY"]!, path: self.sftpArea)
                try? fm.removeItem(atPath: self.sftpDisk)
                try! fm.createDirectory(atPath: self.sftpDisk + "/sub", withIntermediateDirectories: true)
                try! "deep".write(toFile: self.sftpDisk + "/sub/deep.txt", atomically: true, encoding: .utf8)
                self.c.connect(c, password: "secret pass", inNewTab: true)
            }),
            ("wait", {}), ("wait", {}),
            ("sftp panel: upload", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                self.check(r.isRemote && r.remotePath == self.sftpArea, "sftp: panel shows the connection at \(r.remotePath)")
                self.check(r.items.contains { $0.name == "sub" && $0.isDirectory }, "sftp: remote listing in the panel")
                let l: FilePanel = self.c.left
                self.c.window?.makeFirstResponder(l.tableView)
                l.setMarked(["upload.txt", "folder"])
                self.c.remoteTransfer(l.operationItems, from: l, to: r, move: false)
            }),
            ("wait", {}), ("wait", {}),
            ("sftp panel: download", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                let disk = URL(fileURLWithPath: self.sftpDisk)
                self.check((try? String(contentsOf: disk.appendingPathComponent("folder/x.txt"), encoding: .utf8)) == "in folder"
                           && r.items.contains { $0.name == "upload.txt" }, "sftp: upload from local panel")
                self.c.window?.makeFirstResponder(r.tableView)
                r.setMarked(["sub"])
                let target = self.c.left.currentURL.appendingPathComponent("from-server")
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                self.c.left.navigate(to: target)
                self.c.remoteTransfer(r.operationItems, from: r, to: self.c.left, move: false)
            }),
            ("wait", {}), ("wait", {}),
            ("sftp panel: manage", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                self.check(fm.fileExists(atPath: self.c.left.currentURL.appendingPathComponent("sub/deep.txt").path),
                           "sftp: folder download into local panel")
                r.select(name: "upload.txt")
                self.c.remoteRename(r.cursorItem!, to: "renamed.txt")
                self.c.remoteMakeDirectory("made here")
            }),
            ("wait", {}), ("wait", {}),
            ("sftp panel: delete", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                let disk = URL(fileURLWithPath: self.sftpDisk)
                self.check(fm.fileExists(atPath: disk.appendingPathComponent("renamed.txt").path)
                           && fm.fileExists(atPath: disk.appendingPathComponent("made here").path), "sftp: rename and mkdir")
                r.setMarked(["folder", "renamed.txt"])
                self.c.remoteDelete(r.operationItems)
            }),
            ("wait", {}), ("wait", {}),
            ("sftp panel: navigate", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                let disk = URL(fileURLWithPath: self.sftpDisk)
                self.check(!fm.fileExists(atPath: disk.appendingPathComponent("folder").path)
                           && !fm.fileExists(atPath: disk.appendingPathComponent("renamed.txt").path), "sftp: delete")
                r.select(name: "sub")
                r.openCursor()
            }),
            ("wait", {}),
            ("sftp panel: back", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                self.check(r.remotePath.hasSuffix("/sub") && r.items.contains { $0.name == "deep.txt" }, "sftp: Enter opens remote folder")
                r.goParent()
            }),
            ("wait", {}),
            ("sftp panel: disconnect", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                self.check(r.remotePath == self.sftpArea && r.cursorItem?.name == "sub", "sftp: parent keeps cursor on folder")
                self.check(FileJob.testErrors?.isEmpty == true, "sftp: no errors \(FileJob.testErrors ?? [])")
                self.c.disconnect(nil)
                self.check(!r.isRemote, "sftp: disconnect")
                FileJob.testErrors = nil
            }),
            ("ftp panel: connect", {
                guard self.remoteEnv else { return }
                FileJob.testErrors = []
                let local = self.root.appendingPathComponent("panel-ftp")
                try? fm.removeItem(at: local)
                try! fm.createDirectory(at: local.appendingPathComponent("folder"), withIntermediateDirectories: true)
                try! "up".write(to: local.appendingPathComponent("upload.txt"), atomically: true, encoding: .utf8)
                try! "in folder".write(to: local.appendingPathComponent("folder/x.txt"), atomically: true, encoding: .utf8)
                self.c.left.navigate(to: local)
                self.c.window?.makeFirstResponder(self.c.right.tableView)
                let c = Connection(name: "t", kind: .ftp, host: "127.0.0.1", port: 2121, user: "test", path: self.ftpArea)
                try? fm.removeItem(atPath: self.ftpDisk)
                try! fm.createDirectory(atPath: self.ftpDisk + "/sub", withIntermediateDirectories: true)
                try! "deep".write(toFile: self.ftpDisk + "/sub/deep.txt", atomically: true, encoding: .utf8)
                self.c.connect(c, password: "test pass", inNewTab: true)
            }),
            ("wait", {}), ("wait", {}),
            ("ftp panel: upload", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                self.check(r.isRemote && r.remotePath == self.ftpArea, "ftp: panel shows the connection at \(r.remotePath)")
                self.check(r.items.contains { $0.name == "sub" && $0.isDirectory }, "ftp: remote listing in the panel")
                let l: FilePanel = self.c.left
                self.c.window?.makeFirstResponder(l.tableView)
                l.setMarked(["upload.txt", "folder"])
                self.c.remoteTransfer(l.operationItems, from: l, to: r, move: false)
            }),
            ("wait", {}), ("wait", {}),
            ("ftp panel: download", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                let disk = URL(fileURLWithPath: self.ftpDisk)
                self.check((try? String(contentsOf: disk.appendingPathComponent("folder/x.txt"), encoding: .utf8)) == "in folder"
                           && r.items.contains { $0.name == "upload.txt" }, "ftp: upload from local panel")
                self.c.window?.makeFirstResponder(r.tableView)
                r.setMarked(["sub"])
                let target = self.c.left.currentURL.appendingPathComponent("from-server")
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                self.c.left.navigate(to: target)
                self.c.remoteTransfer(r.operationItems, from: r, to: self.c.left, move: false)
            }),
            ("wait", {}), ("wait", {}),
            ("ftp panel: manage", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                self.check(fm.fileExists(atPath: self.c.left.currentURL.appendingPathComponent("sub/deep.txt").path),
                           "ftp: folder download into local panel")
                r.select(name: "upload.txt")
                self.c.remoteRename(r.cursorItem!, to: "renamed.txt")
                self.c.remoteMakeDirectory("made here")
            }),
            ("wait", {}), ("wait", {}),
            ("ftp panel: delete", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                let disk = URL(fileURLWithPath: self.ftpDisk)
                self.check(fm.fileExists(atPath: disk.appendingPathComponent("renamed.txt").path)
                           && fm.fileExists(atPath: disk.appendingPathComponent("made here").path), "ftp: rename and mkdir")
                r.setMarked(["folder", "renamed.txt"])
                self.c.remoteDelete(r.operationItems)
            }),
            ("wait", {}), ("wait", {}),
            ("ftp panel: navigate", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                let disk = URL(fileURLWithPath: self.ftpDisk)
                self.check(!fm.fileExists(atPath: disk.appendingPathComponent("folder").path)
                           && !fm.fileExists(atPath: disk.appendingPathComponent("renamed.txt").path), "ftp: delete")
                r.select(name: "sub")
                r.openCursor()
            }),
            ("wait", {}),
            ("ftp panel: back", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                self.check(r.remotePath.hasSuffix("/sub") && r.items.contains { $0.name == "deep.txt" }, "ftp: Enter opens remote folder")
                r.goParent()
            }),
            ("wait", {}),
            ("ftp panel: disconnect", {
                guard self.remoteEnv else { return }
                let r: FilePanel = self.c.right
                self.check(r.remotePath == self.ftpArea && r.cursorItem?.name == "sub", "ftp: parent keeps cursor on folder")
                self.check(FileJob.testErrors?.isEmpty == true, "ftp: no errors \(FileJob.testErrors ?? [])")
                self.c.disconnect(nil)
                self.check(!r.isRemote, "ftp: disconnect")
                FileJob.testErrors = nil
            }),
            ("verify delete", {
                self.check(!fm.fileExists(atPath: b.appendingPathComponent("sub").path), "permanent delete")
                self.check(ViewerWindowController.hexDump(Data("AB".utf8), limit: 10).hasPrefix("00000000: 41 42"), "hex dump")
                self.check(FileMask("*.txt").matches("A.TXT") && !FileMask("*.txt").matches("a.md"), "file masks")
                self.check(FileMask("*.txt *.md").matches("a.md"), "masks separated by spaces")
                self.check(FileMask("*.*|*.bak").matches("a.txt") && !FileMask("*.*|*.bak").matches("a.bak"), "| exclusion")
                self.check(FileMask("report[1]*").matches("report[1].doc"), "brackets are literal")
                self.check(FileMask("Отчет*").matches("отчет.doc"), "Cyrillic case-insensitive")
                self.check(FileMask("café*").matches("cafe\u{301}.txt"), "Unicode normalization")
                self.check(FileMask("?.txt").matches("я.txt"), "? matches one character")
                self.check(FileMask("*.").matches("README") && !FileMask("*.").matches("a.txt"), "*. = no extension")
                self.check(FileMask("\"my file\"").matches("my file.txt"), "quoted mask with space")
                self.check(ViewerWindowController.decode(Data([0xCF, 0xF0, 0x98]), encoding: .windowsCP1251).hasPrefix("Пр"),
                           "CP1251 decodes despite undefined byte 0x98")
                let big = self.root.appendingPathComponent("big.txt")
                var bigData = Data(repeating: 0x61, count: (1 << 20) - 3)
                bigData.append(contentsOf: Array("НаЙдИ".utf8))
                try? bigData.write(to: big)
                self.check(SearchWindowController.file(big, contains: "найди", data: Data("найди".utf8), caseSensitive: false,
                                                       cancel: CancelFlag()), "chunked search across chunk boundary, case-insensitive")
                self.check(!SearchWindowController.file(big, contains: "найди", data: Data("найди".utf8), caseSensitive: true,
                                                        cancel: CancelFlag()), "case-sensitive search respects case")
            }),
        ]
        if ProcessInfo.processInfo.environment["FA_SHOWCASE_ONLY"] != nil {
            steps = []
            showcase()
            return
        }
        next()
    }

    private func next() {
        guard !steps.isEmpty else {
            if ProcessInfo.processInfo.environment["FA_KEEP"] != nil { showcase(); return }
            if ProcessInfo.processInfo.environment["FA_FULLSCREEN"] != nil, !fullscreenChecked {
                fullscreenChecked = true
                c.window?.toggleFullScreen(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard let w = self.c.window, let content = w.contentView else { return }
                    let screen = w.screen!
                    let menuBottom = screen.frame.maxY - max(screen.safeAreaInsets.top, NSApp.mainMenu?.menuBarHeight ?? 0, 24)
                    // The toolbar is the view whose top edge is highest.
                    let toolbarTopLocal = content.subviews.map(\.frame.maxY).max() ?? 0
                    let toolbarTop = w.convertToScreen(content.convert(NSRect(x: 0, y: toolbarTopLocal, width: 1, height: 0), to: nil)).maxY
                    self.check(w.styleMask.contains(.fullScreen), "entered full screen")
                    self.check(toolbarTop <= menuBottom,
                               "toolbar below menu bar in full screen (toolbar top \(toolbarTop), menu bar bottom \(menuBottom))")
                    print("SHOT", w.windowNumber)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        w.toggleFullScreen(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.next() }
                    }
                }
                return
            }
            print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILURE(S)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        let (_, step) = steps.removeFirst()
        step()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.next() }
    }
}

extension SelfTest {
    /// Leaves the app open with a few windows visible, for screenshots.
    fileprivate func showcase() {
        if let theme = ProcessInfo.processInfo.environment["FA_THEME"] { Theme.schemeName = theme }
        if ProcessInfo.processInfo.environment["FA_SETTINGS"] != nil { c.showSettings(nil) }
        if ProcessInfo.processInfo.environment["FA_USAGE"] != nil {
            DiskUsageWindowController.show(controller: c, folder: URL(fileURLWithPath: "/Applications"))
            return
        }
        if ProcessInfo.processInfo.environment["FA_TREE"] != nil {
            c.left.navigate(to: root.appendingPathComponent("a/sub"))
            c.left.setViewMode(.tree)
            c.left.activate()
            return
        }
        if ProcessInfo.processInfo.environment["FA_TAGS"] != nil {
            let d = root.appendingPathComponent("a")
            let st = FinderTags.standard
            try? FinderTags.write(d.appendingPathComponent("one.txt"), [st[0]])
            try? FinderTags.write(d.appendingPathComponent("two.md"), [st[0], st[4], st[3]])
            try? FinderTags.write(d.appendingPathComponent("sub"), [st[3]])
            c.left.navigate(to: d)
            c.left.activate()
            return
        }
        if ProcessInfo.processInfo.environment["FA_DIFF"] != nil {
            let d = root.appendingPathComponent("diff")
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let base = (1...40).map { "line \($0): the quick brown fox jumps over the lazy dog" }
            var changed = base
            changed[4] = "line 5: the QUICK brown fox jumps over the lazy cat"
            changed.remove(at: 12)
            changed.insert("an inserted line", at: 20)
            changed.insert("another inserted line", at: 21)
            try? base.joined(separator: "\n").write(to: d.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
            try? changed.joined(separator: "\n").write(to: d.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            DiffWindowController.compare(d.appendingPathComponent("old.txt"), d.appendingPathComponent("new.txt"))
            return
        }
        if ProcessInfo.processInfo.environment["FA_SYNC"] != nil {
            let w = SyncWindowController.show(controller: c, left: root.appendingPathComponent("a"), right: root.appendingPathComponent("b"))
            w.compare(nil)
            return
        }
        if ProcessInfo.processInfo.environment["FA_GALLERY"] != nil {
            c.left.navigate(to: root.appendingPathComponent("gallery"), select: "photo-2.png")
            c.left.setViewMode(.thumbnails)
            c.left.activate()
            c.toggleQuickView(nil)
            return
        }
        if let key = ProcessInfo.processInfo.environment["FA_SHOW_REMOTE"] {
            c.window?.makeFirstResponder(c.right.tableView)
            c.connect(Connection(name: "test", kind: .sftp, host: "127.0.0.1", port: 2222, user: NSUserName(), keyFile: key,
                                 path: root.path), password: "secret pass", inNewTab: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.c.showConnections(nil) }
        }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try? FileManager.default.createDirectory(at: a.appendingPathComponent("photos"), withIntermediateDirectories: true)
        c.left.navigate(to: a)
        c.left.newTab(url: b)
        c.left.newTab(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
        c.left.switchTab(0)
        c.left.mark(mask: "*.txt;*.md", on: true)
        c.left.select(name: "two.md")
        c.window?.makeFirstResponder(c.left.tableView)
        // FA_SHOWCASE_RIGHT: folder for the right panel (for screenshots that must not show the home folder).
        let rightFolder = ProcessInfo.processInfo.environment["FA_SHOWCASE_RIGHT"].map { URL(fileURLWithPath: $0) }
        c.right.navigate(to: rightFolder ?? FileManager.default.homeDirectoryForCurrentUser)
        if ProcessInfo.processInfo.environment["FA_KEEP"] == "all" {
            ViewerWindowController.show(url: a.appendingPathComponent("one.txt"))
            SearchWindowController.show(controller: c, startDir: a)
            MultiRenameWindowController.show(urls: c.left.operationItems.map(\.url)) {}
            ArchiveWindowController.show(archive: b.appendingPathComponent("arch.zip"), controller: c)
        }
    }
}
