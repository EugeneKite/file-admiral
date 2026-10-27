enum Help {
    static let keyboard = """
    FileAdmiral — keyboard reference (Total Commander style)
    ==========================================================

    Function keys (on a MacBook hold fn, or enable "Use F1, F2, etc. keys as standard function keys")
      F1            This help
      F2            Rename in place      (reread source: ⌘R)
      F3            View file (Lister)  — on a folder: calculate its size
      F4            Edit file            Shift+F4  create and edit new file
      F5            Copy                 Shift+F5  copy in same folder   Alt+F5  pack
      F6            Move / rename        Shift+F6  rename in place
      F7            New folder           Alt+F7    find files
      F8 / Delete   Move to Trash        Shift+F8 / Shift+Delete  delete permanently
      Alt+F9        Unpack archive

    Panels
      Tab           Switch between left and right panel
      Enter         Open folder / launch file / browse archive
      Backspace     Parent folder        ⌘↑  parent folder   ⌘↓  open
      ⌘PgDn / ⌘⌥↓   Enter package (.app contents)
      ⌘← / ⌘→       Open folder under cursor in left / right panel
      ⌘[ / ⌘]       Back / forward in folder history
      ⌥↓            Folder history menu (or double-click the path bar)
      ⌘D            Directory hotlist    ⌘⇧D  add current folder
      ⌘⇧G           Go to folder…
      ⌘U            Swap panels          ⌘=   target = source
      ⌘R            Reread               ⌘⇧.  show/hide hidden files
      Ctrl+F3..F6   Sort by name / extension / date / size (or click column headers)
      Letters       Quick search (↑/↓ jump to previous/next match, Esc to cancel)

    Selection (marked files are shown in red)
      Space         Mark/unmark; on a folder also calculates its size
      Insert        Mark/unmark and move down
      Shift+↑/↓     Mark while moving    Shift+Home/End/PgUp/PgDn  mark range
      ⌘click        Toggle mark          Shift+click  mark range
      +  /  -       Select / unselect group by mask (*.txt;*.md, end with / for folders)
      *             Invert selection     ⌘A  select all
      ⌘⇧C           Compare directories (marks newer/missing files)

    Tabs (each panel has its own tabs, remembered between launches)
      +  button     New tab; drop a folder on it to open that folder in a new tab
      ×  / middle-click   Close tab; right-click a tab for Duplicate / Close Others / Close Tabs to the Right
      Double-click empty space in the tab bar   New tab
      ⌘T new tab, ⌘⇧T open folder under cursor in new tab, ⌘W close tab, ⌘1…⌘9 go to tab,
      Ctrl+Tab / Ctrl+Shift+Tab or ⌘⇧] / ⌘⇧[ next / previous tab

    Toolbar
      Right-click the toolbar to show or hide the button labels

    Views and tools
      ⌃F2 / ⌃⇧F1 / ⌃F8   List / Thumbnails / Folder tree (also the switch in each drive bar)
      ⌃Q            Quick View: the other panel previews the file under the cursor
      ⌘Z / ⌘⇧Z      Undo / redo copy, move, rename, Move to Trash, new folder, new file
      "In Background" in the Copy/Move dialog queues the job (⌥⌘B shows Background Operations)
      ⌘⇧S           Synchronize Folders (compare and sync the two panels' folders)
      ⌥⌘D           Compare by Content (two marked files, or the cursor files of both panels)
      ⌃1…⌃7         Toggle Finder color tags; Files › Tags, Mark › Select by Tag
      ⌥⌘⇧D / ⌥⌘U    Find Duplicates / Disk Usage map
      Click any folder name in the path bar to go there
      Find Files: "Use Spotlight index" for instant results in indexed locations

    FTP / SFTP (Net menu)
      ⌘K            Connect to Server: SFTP (OpenSSH, keys, ssh-agent, ~/.ssh/config), FTP, FTPS;
                    saved connections keep their password in the macOS Keychain
      ⌘⇧K           Disconnect (or pick a local volume in the drive list)
      In a remote panel: Enter/Backspace browse, F3 view, F4 edit (every save is uploaded back),
      F5/F6 between a local and a remote panel to upload/download, F6 inside one server moves,
      F7 new folder, Shift+F6 rename, F8 delete, drop files from Finder or the other panel to upload,
      "cd path" in the command line

    Settings (⌘,)
      General, Display, Tools and Plugins pages: delete confirmation and Trash, typing mode
      (quick search or classic command line), tab restore, theme and font, visible bars,
      size and date formats, F4 editor, terminal app, Lister encoding

    Command line
      Type in the field at the bottom, Enter runs it with zsh in the current folder.
      "cd path" changes folder. ↑/↓ browse history. ⌘Enter inserts the name under cursor,
      ⌘⇧Enter inserts its full path. ⌥⌘L focuses the command line. ⌥⌘T opens Terminal here.

    Other
      ⌘C / ⌘V       Copy files to / paste files from the clipboard (works with Finder)
      ⌘Y            Quick Look          ⌘I  Finder Get Info    ⌥⌘R  Reveal in Finder
      ⌘M            Multi-Rename Tool   ⌥⌘C copy names, ⌥⌘⇧C copy full paths
      Drag & drop   Copy (hold ⌘ or Shift to move), also to and from Finder

    Lister (F3)
      1 text, 3 hex, 4 image, W toggle wrap, ⌘F find, Esc or F3 closes
    """

    static let plugins = """
    Writing FileAdmiral plugins
    ============================

    A plugin is a folder inside
      ~/Library/Application Support/FileAdmiral/Plugins/
    containing a plugin.json file and (usually) a script. Use Plugins → Install Sample Plugins
    to get working examples, and Plugins → Reload Plugins after editing.

    plugin.json fields
      name          Title shown in the menu / toolbar (required)
      command       What to run (required). "./run.sh" runs a script from the plugin folder;
                    anything else is a zsh command line. Selected files are passed as "$@".
      type          "command" (default) — a menu command
                    "viewer"  — an extra tab in the Lister (F3); its output is shown as text
      description   Tooltip text
      input         command plugins: "selection" (default: marked files, or the file under the
                    cursor), "cursor" (only the file under the cursor), "folder" (the current
                    folder), "none"
      output        "refresh" (default for commands: reread panels), "viewer" (show the output
                    in a Lister window), "none"
      fileMask      Only accept matching files, e.g. "*.jpg;*.png"
      shortcut      Keyboard shortcut, e.g. "cmd+shift+j", "ctrl+alt+f9"
      toolbar       true to add a toolbar button
      icon          SF Symbols name for menu/toolbar, e.g. "photo", "hammer"
      confirm       Question asked before running; {count} is replaced with the file count

    Environment variables available to the script
      FA_SOURCE_DIR   folder of the active panel
      FA_TARGET_DIR   folder of the other panel
      FA_CURSOR       file under the cursor
      FA_SELECTED     selected files, one per line
      FA_PLUGIN_DIR   the plugin's own folder

    Example — "Resize images to 50%" (plugin.json):
      {
        "name": "Resize 50%",
        "command": "./run.sh",
        "fileMask": "*.jpg;*.png;*.heic",
        "toolbar": true,
        "icon": "arrow.down.right.and.arrow.up.left"
      }
    run.sh (make it executable: chmod +x run.sh):
      #!/bin/zsh
      for f in "$@"; do
        w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')
        sips --resampleWidth $((w / 2)) "$f" --out "$FA_TARGET_DIR/${f:t}"
      done

    Scripts run with your user permissions and a login shell, so Homebrew tools are on PATH.
    Only install plugins you trust.
    """
}
