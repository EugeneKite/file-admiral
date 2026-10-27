import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var main: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let selfTestDir = ProcessInfo.processInfo.environment["FA_SELFTEST"]
        PermissionsWindowController.fdaAtLaunch = PermissionsWindowController.hasFullDiskAccess
        NSApp.appearance = Theme.appearance
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { _ in
            NSApp.appearance = Theme.appearance
        }
        // "Automatic" follows the system light/dark setting.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { _ in
            guard Theme.schemeName == Theme.automaticName else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: .themeChanged, object: nil)
            }
        }
        main = MainWindowController()
        NSApp.mainMenu = MenuBuilder(target: main).build()
        main.showWindow(nil)
        main.reloadPlugins()
        main.rebuildNetMenu()
        NotificationCenter.default.addObserver(main!, selector: #selector(MainWindowController.rebuildNetMenu(_:)),
                                               name: .connectionsChanged, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        if let dir = selfTestDir {
            // Tests always start in a normal window (a restored full-screen Space would hide it).
            main.window?.isRestorable = false
            if main.window?.styleMask.contains(.fullScreen) == true { main.window?.toggleFullScreen(nil) }
            selfTest = SelfTest(controller: main, root: URL(fileURLWithPath: dir))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.selfTest?.run() }
        } else {
            PermissionsWindowController.showOnFirstLaunchIfNeeded()
        }
    }

    private var selfTest: SelfTest?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        main?.saveState()
    }
}

/// Builds the TC-style menu bar: Files, Mark, Commands, Show, Tabs, Configuration.
struct MenuBuilder {
    let target: MainWindowController

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                      target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = mods
        // Panel commands go through the responder chain, so they only act while the main window is
        // in front (F8 or Cmd+W in the Lister must not touch the panels).
        mi.target = target
        return mi
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach { m.addItem($0) }
        top.submenu = m
        return top
    }

    private var sep: NSMenuItem { .separator() }

    func build() -> NSMenu {
        let t = target
        let main = NSMenu()

        main.addItem(menu("FileAdmiral", [
            item("About FileAdmiral", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", [], target: NSApp),
            sep,
            item("Settings…", #selector(MainWindowController.showSettings(_:)), ",", [.command], target: t),
            sep,
            item("Hide FileAdmiral", #selector(NSApplication.hide(_:)), "h", [.command], target: NSApp),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", [], target: NSApp),
            sep,
            item("Quit FileAdmiral", #selector(NSApplication.terminate(_:)), "q", [.command], target: NSApp),
        ]))

        main.addItem(menu("Files", [
            item("View", #selector(MainWindowController.viewFile(_:)), fkey(3), []),
            item("Edit", #selector(MainWindowController.editFile(_:)), fkey(4), []),
            item("Edit New File…", #selector(MainWindowController.newFile(_:)), fkey(4), [.shift]),
            item("Quick Look", #selector(MainWindowController.quickLook(_:)), "y", [.command]),
            sep,
            item("Copy…", #selector(MainWindowController.copyFiles(_:)), fkey(5), []),
            item("Copy in Same Folder…", #selector(MainWindowController.copyInPlace(_:)), fkey(5), [.shift]),
            item("Rename/Move…", #selector(MainWindowController.moveFiles(_:)), fkey(6), []),
            item("Rename…", #selector(MainWindowController.renameFile(_:)), fkey(2), []),
            item("New Folder…", #selector(MainWindowController.makeDirectory(_:)), fkey(7), []),
            item("Move to Trash", #selector(MainWindowController.deleteToTrash(_:)), fkey(8), []),
            item("Delete Permanently…", #selector(MainWindowController.deletePermanently(_:)), fkey(8), [.shift]),
            sep,
            item("Pack…", #selector(MainWindowController.packFiles(_:)), fkey(5), [.option]),
            item("Unpack…", #selector(MainWindowController.unpackFiles(_:)), fkey(9), [.option]),
            item("Multi-Rename Tool…", #selector(MainWindowController.multiRename(_:)), "m", [.command]),
            item("Compare by Content…", #selector(MainWindowController.compareFiles(_:)), "d", [.command, .option]),
            sep,
            item("Copy Names to Clipboard", #selector(MainWindowController.copyNames(_:)), "c", [.command, .option]),
            item("Copy Names with Full Path", #selector(MainWindowController.copyFullNames(_:)), "c", [.command, .option, .shift]),
            item("Get Info", #selector(MainWindowController.getInfo(_:)), "i", [.command]),
            item("Reveal in Finder", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .option]),
            item("Share…", #selector(MainWindowController.shareFiles(_:)), "s", [.command, .option]),
            {
                // Filled when opened (menuNeedsUpdate); the ⌃1…⌃7 shortcuts work while it is closed too
                // because AppKit updates delegate menus before matching key equivalents.
                let tags = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
                let sub = NSMenu(title: "Tags")
                sub.delegate = t
                tags.submenu = sub
                return tags
            }(),
            sep,
            item("Quit", #selector(NSApplication.terminate(_:)), "", [], target: NSApp),
        ]))

        main.addItem(menu("Edit", [
            item("Undo", Selector(("undo:")), "z", [.command], target: nil),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], target: nil),
            sep,
            item("Cut", #selector(NSText.cut(_:)), "x", [.command], target: nil),
            item("Copy", #selector(NSText.copy(_:)), "c", [.command], target: nil),
            item("Paste", #selector(NSText.paste(_:)), "v", [.command], target: nil),
            item("Select All", #selector(NSText.selectAll(_:)), "a", [.command], target: nil),
            sep,
            {
                let f = item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", [.command], target: nil)
                f.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                return f
            }(),
            {
                let f = item("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command], target: nil)
                f.tag = Int(NSFindPanelAction.next.rawValue)
                return f
            }(),
        ]))

        main.addItem(menu("Mark", [
            item("Select Group…", #selector(MainWindowController.selectGroup(_:)), "=", [.command, .option]),
            item("Unselect Group…", #selector(MainWindowController.unselectGroup(_:)), "-", [.command, .option]),
            item("Select All", #selector(MainWindowController.selectAllFiles(_:)), "a", [.command, .shift]),
            item("Unselect All", #selector(MainWindowController.unselectAllFiles(_:)), "a", [.command, .option]),
            item("Invert Selection", #selector(MainWindowController.invertSelection(_:)), "8", [.command, .option]),
            item("Select Files with Same Extension", #selector(MainWindowController.selectSameExtension(_:)), "e", [.command, .option]),
            sep,
            {
                let byTag = NSMenuItem(title: "Select by Tag", action: nil, keyEquivalent: "")
                let sub = NSMenu(title: "Select by Tag")
                sub.delegate = t
                byTag.submenu = sub
                return byTag
            }(),
            item("Compare Directories", #selector(MainWindowController.compareDirectories(_:)), "c", [.command, .shift]),
            item("Synchronize Folders…", #selector(MainWindowController.synchronizeFolders(_:)), "s", [.command, .shift]),
        ]))

        main.addItem(menu("Commands", [
            item("Find Files…", #selector(MainWindowController.searchFiles(_:)), fkey(7), [.option]),
            item("Directory Hotlist", #selector(MainWindowController.showHotlist(_:)), "d", [.command]),
            item("Add Current Directory to Hotlist", #selector(MainWindowController.addToHotlist(_:)), "d", [.command, .shift]),
            item("Folder History  (⌥↓)", #selector(MainWindowController.showHistoryMenu(_:)), "", []),
            item("Go to Folder…", #selector(MainWindowController.goToFolder(_:)), "g", [.command, .shift]),
            sep,
            item("Back", #selector(MainWindowController.goBack(_:)), "[", [.command]),
            item("Forward", #selector(MainWindowController.goForward(_:)), "]", [.command]),
            item("Parent Folder  (⌘↑)", #selector(MainWindowController.goParent(_:)), "", []),
            item("Open  (⌘↓)", #selector(MainWindowController.openCursorItem(_:)), "", []),
            item("Home Folder", #selector(MainWindowController.goHome(_:)), "h", [.command, .shift]),
            item("Root Folder", #selector(MainWindowController.goRoot(_:)), "\\", [.command]),
            sep,
            item("Background Operations…", #selector(MainWindowController.showBackgroundOperations(_:)), "b", [.command, .option],
                 target: t),
            item("Find Duplicates…", #selector(MainWindowController.findDuplicates(_:)), "d", [.command, .option, .shift]),
            item("Disk Usage…", #selector(MainWindowController.showDiskUsage(_:)), "u", [.command, .option]),
            item("Swap Panels", #selector(MainWindowController.swapPanels(_:)), "u", [.command]),
            item("Target = Source", #selector(MainWindowController.targetEqualsSource(_:)), "=", [.command]),
            item("Calculate All Folder Sizes", #selector(MainWindowController.calculateAllSizes(_:)), "\r", [.option, .shift]),
            sep,
            item("Command Line", #selector(MainWindowController.focusCommandLine(_:)), "l", [.command, .option]),
            item("Open Terminal Here", #selector(MainWindowController.openTerminal(_:)), "t", [.command, .option]),
        ]))

        main.addItem(menu("Net", []))

        main.addItem(menu("Show", [
            item("Details", #selector(MainWindowController.showDetailsView(_:)), fkey(2), [.control]),
            item("Thumbnails", #selector(MainWindowController.showThumbnailsView(_:)), fkey(1), [.control, .shift]),
            {
                let sizeItem = NSMenuItem(title: "Thumbnail Size", action: nil, keyEquivalent: "")
                let sub = NSMenu(title: "Thumbnail Size")
                for size in Settings.ThumbnailSize.allCases {
                    let mi = item(size.title, #selector(MainWindowController.chooseThumbnailSize(_:)), "", [])
                    mi.representedObject = size.rawValue
                    sub.addItem(mi)
                }
                sizeItem.submenu = sub
                return sizeItem
            }(),
            item("Folder Tree", #selector(MainWindowController.toggleFolderTree(_:)), fkey(8), [.control]),
            item("Quick View Panel", #selector(MainWindowController.toggleQuickView(_:)), "q", [.control]),
            sep,
            item("Hidden Files", #selector(MainWindowController.toggleHidden(_:)), ".", [.command, .shift]),
            sep,
            item("Sort by Name", #selector(MainWindowController.sortByName(_:)), fkey(3), [.control]),
            item("Sort by Extension", #selector(MainWindowController.sortByExt(_:)), fkey(4), [.control]),
            item("Sort by Date/Time", #selector(MainWindowController.sortByDate(_:)), fkey(5), [.control]),
            item("Sort by Size", #selector(MainWindowController.sortBySize(_:)), fkey(6), [.control]),
            item("Reverse Order", #selector(MainWindowController.reverseSort(_:)), "", []),
            sep,
            item("Reread Source", #selector(MainWindowController.refresh(_:)), "r", [.command]),
        ]))

        main.addItem(menu("Tabs", [
            item("New Tab", #selector(MainWindowController.newTab(_:)), "t", [.command]),
            item("Open Folder Under Cursor in New Tab", #selector(MainWindowController.newTabFromCursor(_:)), "t", [.command, .shift]),
            item("Close Tab", #selector(MainWindowController.closeTab(_:)), "w", [.command]),
            item("Next Tab", #selector(MainWindowController.nextTab(_:)), "]", [.command, .shift]),
            item("Previous Tab", #selector(MainWindowController.prevTab(_:)), "[", [.command, .shift]),
        ]))

        main.addItem(menu("Plugins", []))

        main.addItem(menu("Configuration", [
            item("Settings…", #selector(MainWindowController.showSettings(_:)), "", [], target: t),
            item("Permissions…", #selector(MainWindowController.showPermissions(_:)), ",", [.command, .option], target: t),
            sep,
            {
                let themeItem = NSMenuItem(title: "Color Theme", action: nil, keyEquivalent: "")
                let sub = NSMenu(title: "Color Theme")
                for name in [Theme.automaticName] + ColorScheme.all.map(\.name) {
                    let mi = item(name, #selector(MainWindowController.chooseColorScheme(_:)), "", [], target: t)
                    mi.representedObject = name
                    sub.addItem(mi)
                    if name == Theme.automaticName { sub.addItem(.separator()) }
                }
                themeItem.submenu = sub
                return themeItem
            }(),
            item("Bigger Font", #selector(MainWindowController.biggerFont(_:)), "+", [.command], target: t),
            item("Smaller Font", #selector(MainWindowController.smallerFont(_:)), "-", [.command], target: t),
            item("Default Font Size", #selector(MainWindowController.defaultFontSize(_:)), "0", [.command], target: t),
            sep,
            item("Choose Editor for F4…", #selector(MainWindowController.chooseEditor(_:)), "", [], target: t),
        ]))

        let windowMenu = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", [.command, .control], target: nil),
            item("Zoom", #selector(NSWindow.performZoom(_:)), "", [], target: nil),
            sep,
            // After Tabs > Close Tab (also Cmd+W): closes Lister/Find/other windows; in the main window the
            // tab command comes first in the menu bar and handles the key.
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command], target: nil),
        ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu

        main.addItem(menu("Help", [
            item("Keyboard Shortcuts", #selector(MainWindowController.showKeyboardHelp(_:)), fkey(1), [], target: t),
        ]))
        return main
    }
}
