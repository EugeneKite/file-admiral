import AppKit

/// Script plugins.
///
/// Each plugin is a folder in ~/Library/Application Support/FileAdmiral/Plugins containing a
/// `plugin.json` manifest and usually a script. Two kinds exist:
///
/// - "command": appears in the Plugins menu (and optionally the toolbar). The script receives the
///   selected files as arguments and these environment variables:
///   FA_SOURCE_DIR, FA_TARGET_DIR, FA_CURSOR, FA_SELECTED (newline-separated), FA_PLUGIN_DIR.
/// - "viewer": adds a mode to the Lister (F3) for files matching `fileMask`; the script gets the
///   file path as its only argument and its output is shown as text.
struct Plugin {
    enum Kind: String { case command, viewer }
    enum Input: String { case selection, cursor, folder, none }
    enum Output: String { case none, viewer, refresh }

    let id: String
    let folder: URL
    let name: String
    let description: String
    let kind: Kind
    let command: String
    let input: Input
    let output: Output
    let fileMask: FileMask?
    let shortcut: (key: String, modifiers: NSEvent.ModifierFlags)?
    let shortcutText: String?
    let toolbar: Bool
    let icon: String
    let confirm: String?

    /// Shell command line; the plugin folder is the base for relative script paths.
    var shellCommand: String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("./") {
            // Through the environment variable, so a plugin folder path with quotes, `$` or spaces needs no escaping.
            return "\"$FA_PLUGIN_DIR\"/\(trimmed.dropFirst(2))"
        }
        return trimmed
    }

    func accepts(_ name: String) -> Bool {
        fileMask?.matches(name) ?? true
    }
}

final class PluginManager {
    static let shared = PluginManager()

    private(set) var plugins: [Plugin] = []
    private(set) var errors: [String] = []

    var folder: URL {
        if let dir = ProcessInfo.processInfo.environment["FA_PLUGINS_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FileAdmiral/Plugins")
    }

    var commandPlugins: [Plugin] { plugins.filter { $0.kind == .command } }

    func viewerPlugins(for url: URL) -> [Plugin] {
        plugins.filter { $0.kind == .viewer && $0.accepts(url.lastPathComponent) }
    }

    func reload() {
        plugins.removeAll()
        errors.removeAll()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return
        }
        for dir in dirs.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            where dir.isExistingDirectory {
            let manifest = dir.appendingPathComponent("plugin.json")
            guard fm.fileExists(atPath: manifest.path) else { continue }
            do {
                plugins.append(try parse(manifest, folder: dir))
            } catch {
                errors.append("\(dir.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private struct ManifestError: LocalizedError {
        let errorDescription: String?
    }

    private func parse(_ manifest: URL, folder: URL) throws -> Plugin {
        let data = try Data(contentsOf: manifest)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManifestError(errorDescription: "plugin.json must contain a JSON object")
        }
        guard let name = json["name"] as? String, !name.isEmpty else {
            throw ManifestError(errorDescription: "missing \"name\"")
        }
        guard let command = json["command"] as? String, !command.isEmpty else {
            throw ManifestError(errorDescription: "missing \"command\"")
        }
        let kindText = json["type"] as? String ?? "command"
        guard let kind = Plugin.Kind(rawValue: kindText) else {
            throw ManifestError(errorDescription: "unknown type \"\(kindText)\" (use command or viewer)")
        }
        let inputText = json["input"] as? String ?? "selection"
        guard let input = Plugin.Input(rawValue: inputText) else {
            throw ManifestError(errorDescription: "unknown input \"\(inputText)\" (use selection, cursor, folder or none)")
        }
        let outputText = json["output"] as? String ?? (kind == .viewer ? "viewer" : "refresh")
        guard let output = Plugin.Output(rawValue: outputText) else {
            throw ManifestError(errorDescription: "unknown output \"\(outputText)\" (use none, viewer or refresh)")
        }
        var shortcut: (String, NSEvent.ModifierFlags)?
        let shortcutText = json["shortcut"] as? String
        if let shortcutText {
            guard let parsed = Self.parseShortcut(shortcutText) else {
                throw ManifestError(errorDescription: "can't understand shortcut \"\(shortcutText)\" (example: cmd+shift+p)")
            }
            shortcut = parsed
        }
        return Plugin(
            id: folder.lastPathComponent, folder: folder, name: name,
            description: json["description"] as? String ?? "",
            kind: kind, command: command, input: input, output: output,
            fileMask: (json["fileMask"] as? String).map(FileMask.init),
            shortcut: shortcut, shortcutText: shortcutText,
            toolbar: json["toolbar"] as? Bool ?? false,
            icon: json["icon"] as? String ?? "puzzlepiece.extension",
            confirm: json["confirm"] as? String)
    }

    /// Parses "cmd+shift+p", "ctrl+alt+f5", "opt+cmd+k".
    static func parseShortcut(_ text: String) -> (String, NSEvent.ModifierFlags)? {
        var mods: NSEvent.ModifierFlags = []
        var key: String?
        for part in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": mods.insert(.command)
            case "shift", "⇧": mods.insert(.shift)
            case "alt", "opt", "option", "⌥": mods.insert(.option)
            case "ctrl", "control", "⌃": mods.insert(.control)
            default:
                if part.count == 1 {
                    key = part
                } else if part.hasPrefix("f"), let n = Int(part.dropFirst()), (1...20).contains(n) {
                    key = fkey(n)
                } else {
                    return nil
                }
            }
        }
        guard let key else { return nil }
        return (key, mods)
    }

    // MARK: - Running

    func run(_ plugin: Plugin, controller: MainWindowController) {
        let source = controller.active!
        let target = controller.other
        let items: [FileItem]
        switch plugin.input {
        case .selection: items = source.operationItems
        case .cursor: items = source.cursorItem.flatMap { $0.isParent ? nil : [$0] } ?? []
        case .folder, .none: items = []
        }
        if plugin.input == .selection || plugin.input == .cursor {
            guard !items.isEmpty else {
                Dialogs.info(plugin.name, "Select one or more files first.")
                return
            }
            let rejected = items.filter { !plugin.accepts($0.name) }
            if !rejected.isEmpty {
                Dialogs.info(plugin.name, "\"\(plugin.name)\" only works with files matching \(plugin.fileMask?.patterns.joined(separator: ";") ?? "*").\n"
                             + "Not supported: " + rejected.prefix(5).map(\.name).joined(separator: ", "))
                return
            }
        }
        if let confirm = plugin.confirm {
            let text = confirm.replacingOccurrences(of: "{count}", with: "\(items.count)")
            guard Dialogs.confirm(plugin.name, text) else { return }
        }

        let paths = plugin.input == .folder ? [source.currentURL.path] : items.map(\.url.path)
        var env = ProcessInfo.processInfo.environment
        env["FA_SOURCE_DIR"] = source.currentURL.path
        env["FA_TARGET_DIR"] = target.currentURL.path
        env["FA_CURSOR"] = source.cursorItem.flatMap { $0.isParent ? nil : $0.url.path } ?? ""
        env["FA_SELECTED"] = items.map(\.url.path).joined(separator: "\n")
        env["FA_PLUGIN_DIR"] = plugin.folder.path
        // "$@" receives the file paths; zsh -l gives the user's PATH (Homebrew tools etc.).
        let args = ["-lc", plugin.shellCommand + " \"$@\"", plugin.name] + paths
        TaskRunner.run(title: plugin.name, executable: "/bin/zsh", arguments: args, cwd: source.currentURL,
                       window: controller.window, environment: env) { status, output in
            controller.refresh(nil)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if status != 0 {
                ViewerWindowController.show(text: output + "\n[exit code \(status)]", title: "\(plugin.name) — failed")
            } else if plugin.output == .viewer && !trimmed.isEmpty {
                ViewerWindowController.show(text: output, title: plugin.name)
            }
        }
    }

    /// Runs a viewer plugin synchronously off the main thread and returns its output.
    func render(_ plugin: Plugin, file: URL, completion: @escaping (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", plugin.shellCommand + " \"$@\"", plugin.name, file.path]
        p.currentDirectoryURL = file.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env["FA_PLUGIN_DIR"] = plugin.folder.path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            completion("Cannot run plugin: \(error.localizedDescription)")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                completion(p.terminationStatus == 0 ? text : text + "\n[exit code \(p.terminationStatus)]")
            }
        }
    }

    // MARK: - Samples

    private struct Sample {
        let id: String
        let manifest: [String: Any]
        let script: String
    }

    private let samples: [Sample] = [
        Sample(id: "image-info", manifest: [
            "name": "Image Info", "type": "viewer", "command": "./run.sh",
            "description": "Shows image size, color profile and camera data in the Lister.",
            "fileMask": "*.jpg;*.jpeg;*.png;*.heic;*.heif;*.gif;*.tif;*.tiff;*.webp;*.bmp;*.avif",
        ], script: """
            #!/bin/zsh
            sips -g all "$1"
            echo
            mdls -name kMDItemAcquisitionMake -name kMDItemAcquisitionModel -name kMDItemContentCreationDate \\
                 -name kMDItemLatitude -name kMDItemLongitude "$1"
            """),
        Sample(id: "file-metadata", manifest: [
            "name": "Spotlight Metadata", "type": "viewer", "command": "./run.sh",
            "description": "Shows all Spotlight metadata of a file (duration, codecs, authors, …).",
        ], script: """
            #!/bin/zsh
            mdls "$1"
            """),
        Sample(id: "checksums", manifest: [
            "name": "Checksums (SHA-256)", "command": "./run.sh", "output": "viewer",
            "description": "Calculates SHA-256 checksums of the selected files.",
            "shortcut": "ctrl+alt+s", "icon": "number.circle.fill",
        ], script: """
            #!/bin/zsh
            for f in "$@"; do
              if [[ -f "$f" ]]; then shasum -a 256 "$f"; else echo "skipped folder: $f"; fi
            done
            """),
        Sample(id: "convert-to-jpeg", manifest: [
            "name": "Convert Images to JPEG", "command": "./run.sh", "output": "refresh",
            "description": "Converts selected images to JPEG in the other panel's folder.",
            "fileMask": "*.png;*.heic;*.heif;*.tif;*.tiff;*.gif;*.bmp;*.webp;*.avif",
            "confirm": "Convert {count} image(s) to JPEG in the other panel?",
            "toolbar": true, "icon": "photo.on.rectangle.angled",
        ], script: """
            #!/bin/zsh
            for f in "$@"; do
              out="$FA_TARGET_DIR/${${f:t}:r}.jpg"
              sips -s format jpeg -s formatOptions 90 "$f" --out "$out" >/dev/null || echo "failed: $f"
            done
            """),
        Sample(id: "git-status", manifest: [
            "name": "Git Status", "command": "./run.sh", "input": "folder", "output": "viewer",
            "description": "Shows git status and recent commits of the current folder.",
            "shortcut": "ctrl+alt+g", "icon": "arrow.triangle.branch",
        ], script: """
            #!/bin/zsh
            cd "$FA_SOURCE_DIR" || exit 1
            git status && echo && git log --oneline -n 15
            """),
        Sample(id: "open-in-vscode", manifest: [
            "name": "Open in VS Code", "command": "./run.sh", "input": "cursor", "output": "none",
            "description": "Opens the file or folder under the cursor in Visual Studio Code.",
            "toolbar": true, "icon": "chevron.left.forwardslash.chevron.right",
        ], script: """
            #!/bin/zsh
            open -a "Visual Studio Code" "$@"
            """),
    ]

    /// Copies the sample plugins into the plugins folder (existing plugins are not overwritten).
    @discardableResult
    func installSamples() -> [String] {
        let fm = FileManager.default
        var installed: [String] = []
        for s in samples {
            let dir = folder.appendingPathComponent(s.id)
            if fm.fileExists(atPath: dir.path) { continue }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let json = try JSONSerialization.data(withJSONObject: s.manifest, options: [.prettyPrinted, .sortedKeys])
                try json.write(to: dir.appendingPathComponent("plugin.json"))
                let script = dir.appendingPathComponent("run.sh")
                try (s.script + "\n").write(to: script, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
                installed.append(s.manifest["name"] as? String ?? s.id)
            } catch {
                errors.append("\(s.id): \(error.localizedDescription)")
            }
        }
        reload()
        return installed
    }
}
