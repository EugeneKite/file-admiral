import AppKit

/// A named set of panel colors.
struct ColorScheme {
    let name: String
    let isDark: Bool
    let panelBackground: NSColor
    let text: NSColor
    let folderText: NSColor
    let hiddenText: NSColor
    let marked: NSColor
    let markedOnCursor: NSColor
    let cursor: NSColor
    let cursorText: NSColor
    let cursorInactive: NSColor
    let activeHeader: NSColor
    let activeHeaderText: NSColor
    let inactiveHeader: NSColor
    let inactiveHeaderText: NSColor
    let barBackground: NSColor
    let quickSearchBackground: NSColor
    /// Full-window retro styling (Norton Commander): colored chrome, column headers and DOS-style F-key bar.
    var retro: RetroChrome? = nil
}

/// Colors for themes that restyle the whole window, not just the panels.
struct RetroChrome {
    let windowBackground: NSColor
    let barText: NSColor
    let columnHeaderBackground: NSColor
    let columnHeaderText: NSColor
    let statusText: NSColor
    let commandBackground: NSColor
    let commandText: NSColor
    let fkeyNumber: NSColor
    let fkeyNumberBackground: NSColor
    let fkeyLabel: NSColor
    let fkeyLabelBackground: NSColor
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

private func hex(_ v: UInt32) -> NSColor {
    rgb(CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
}

extension ColorScheme {
    static let classic = ColorScheme(
        name: "Classic", isDark: false,
        panelBackground: .white, text: .black, folderText: .black, hiddenText: NSColor(white: 0.55, alpha: 1),
        marked: rgb(0.86, 0, 0), markedOnCursor: rgb(1, 0.88, 0.25),
        cursor: rgb(0.05, 0.36, 0.85), cursorText: .white, cursorInactive: NSColor(white: 0.85, alpha: 1),
        activeHeader: rgb(0.05, 0.30, 0.68), activeHeaderText: .white,
        inactiveHeader: NSColor(white: 0.80, alpha: 1), inactiveHeaderText: .black,
        barBackground: NSColor(white: 0.925, alpha: 1), quickSearchBackground: rgb(1, 1, 0.8))

    static let norton = ColorScheme(
        name: "Norton Commander", isDark: false,
        panelBackground: rgb(0, 0, 0.55), text: rgb(0.33, 1, 1), folderText: .white, hiddenText: rgb(0.2, 0.62, 0.7),
        marked: rgb(1, 1, 0.33), markedOnCursor: rgb(1, 1, 0.33),
        cursor: rgb(0, 0.66, 0.66), cursorText: .black, cursorInactive: rgb(0, 0.3, 0.5),
        activeHeader: rgb(0, 0.66, 0.66), activeHeaderText: .black,
        inactiveHeader: rgb(0, 0, 0.42), inactiveHeaderText: rgb(0.33, 1, 1),
        barBackground: rgb(0, 0.66, 0.66), quickSearchBackground: rgb(0.33, 1, 1),
        retro: RetroChrome(
            windowBackground: .black, barText: .black,
            columnHeaderBackground: rgb(0, 0, 0.55), columnHeaderText: rgb(1, 1, 0.33),
            statusText: rgb(0.33, 1, 1), commandBackground: .black, commandText: NSColor(white: 0.75, alpha: 1),
            fkeyNumber: .white, fkeyNumberBackground: .black, fkeyLabel: .black, fkeyLabelBackground: rgb(0, 0.66, 0.66)))

    static let dark = ColorScheme(
        name: "Dark", isDark: true,
        panelBackground: NSColor(white: 0.12, alpha: 1), text: NSColor(white: 0.86, alpha: 1),
        folderText: NSColor(white: 0.97, alpha: 1), hiddenText: NSColor(white: 0.48, alpha: 1),
        marked: rgb(1, 0.42, 0.36), markedOnCursor: rgb(1, 0.88, 0.4),
        cursor: rgb(0.16, 0.38, 0.74), cursorText: .white, cursorInactive: NSColor(white: 0.26, alpha: 1),
        activeHeader: rgb(0.16, 0.38, 0.74), activeHeaderText: .white,
        inactiveHeader: NSColor(white: 0.24, alpha: 1), inactiveHeaderText: NSColor(white: 0.85, alpha: 1),
        barBackground: NSColor(white: 0.17, alpha: 1), quickSearchBackground: rgb(0.36, 0.33, 0.12))

    static let solarizedLight = ColorScheme(
        name: "Solarized Light", isDark: false,
        panelBackground: hex(0xFDF6E3), text: hex(0x586E75), folderText: hex(0x073642), hiddenText: hex(0x93A1A1),
        marked: hex(0xDC322F), markedOnCursor: rgb(1, 0.86, 0.35),
        cursor: hex(0x268BD2), cursorText: .white, cursorInactive: hex(0xEEE8D5),
        activeHeader: hex(0x268BD2), activeHeaderText: .white,
        inactiveHeader: hex(0xEEE8D5), inactiveHeaderText: hex(0x586E75),
        barBackground: hex(0xEEE8D5), quickSearchBackground: rgb(1, 0.95, 0.75))

    static let solarizedDark = ColorScheme(
        name: "Solarized Dark", isDark: true,
        panelBackground: hex(0x002B36), text: hex(0x93A1A1), folderText: hex(0xEEE8D5), hiddenText: hex(0x586E75),
        marked: rgb(0.98, 0.38, 0.33), markedOnCursor: rgb(1, 0.86, 0.35),
        cursor: hex(0x268BD2), cursorText: .white, cursorInactive: hex(0x073642),
        activeHeader: hex(0x268BD2), activeHeaderText: .white,
        inactiveHeader: hex(0x073642), inactiveHeaderText: hex(0x93A1A1),
        barBackground: hex(0x073642), quickSearchBackground: rgb(0.25, 0.3, 0.1))

    static let all: [ColorScheme] = [.classic, .norton, .dark, .solarizedLight, .solarizedDark]
}

extension Notification.Name {
    /// Posted when the color scheme or font size changes.
    static let themeChanged = Notification.Name("FileAdmiralThemeChanged")
}

/// Fonts and colors in use. Colors come from the selected color scheme.
enum Theme {
    static let automaticName = "Automatic"
    private static let defaultFontSize: CGFloat = 12

    /// Selected scheme name, or "Automatic" (Classic in light mode, Dark in dark mode).
    static var schemeName: String {
        get { UserDefaults.standard.string(forKey: "colorScheme") ?? ColorScheme.classic.name }
        set {
            UserDefaults.standard.set(newValue, forKey: "colorScheme")
            changed()
        }
    }

    static var current: ColorScheme {
        if schemeName == automaticName {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? .dark : .classic
        }
        return ColorScheme.all.first { $0.name == schemeName } ?? .classic
    }

    /// Light/dark window chrome matching the scheme; nil follows the system (Automatic).
    static var appearance: NSAppearance? {
        if schemeName == automaticName { return nil }
        return NSAppearance(named: current.isDark ? .darkAqua : .aqua)
    }

    static var fontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: "fontSize")
            return v > 0 ? CGFloat(v) : defaultFontSize
        }
        set {
            UserDefaults.standard.set(Double(min(max(newValue, 9), 24)), forKey: "fontSize")
            changed()
        }
    }

    static func resetFontSize() {
        UserDefaults.standard.removeObject(forKey: "fontSize")
        changed()
    }

    private static func changed() {
        NotificationCenter.default.post(name: .themeChanged, object: nil)
    }

    static var font: NSFont { .systemFont(ofSize: fontSize) }
    static var boldFont: NSFont { .boldSystemFont(ofSize: fontSize) }
    static var smallFont: NSFont { .systemFont(ofSize: 11) }
    static var monoFont: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    static var attrFont: NSFont { .monospacedSystemFont(ofSize: max(fontSize - 1, 9), weight: .regular) }
    static var rowHeight: CGFloat { (fontSize * 1.5).rounded() }

    static var marked: NSColor { current.marked }
    static var markedOnCursor: NSColor { current.markedOnCursor }
    static var activeHeader: NSColor { current.activeHeader }
    static var inactiveHeader: NSColor { current.inactiveHeader }
    static var barBackground: NSColor { current.barBackground }
    static var quickSearchBackground: NSColor { current.quickSearchBackground }
    static let toolTeal = NSColor(srgbRed: 0.0, green: 0.52, blue: 0.58, alpha: 1)
}

enum Fmt {
    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    static func int(_ v: Int64) -> String {
        numberFormatter.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// Kilobytes, rounded up, the way TC's status bar shows them.
    static func kb(_ bytes: Int64) -> String {
        int((bytes + 1023) / 1024)
    }

    static func bytes(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
    }

    private static let dateFormatters: [Settings.DateStyle: DateFormatter] = {
        var result: [Settings.DateStyle: DateFormatter] = [:]
        for style in Settings.DateStyle.allCases {
            let f = DateFormatter()
            switch style {
            case .european: f.dateFormat = "dd.MM.yyyy HH:mm"
            case .iso: f.dateFormat = "yyyy-MM-dd HH:mm"
            case .us: f.dateFormat = "MM/dd/yyyy h:mm a"
            case .system:
                f.dateStyle = .short
                f.timeStyle = .short
            }
            result[style] = f
        }
        return result
    }()

    static func date(_ d: Date) -> String {
        (dateFormatters[Settings.dateStyle] ?? dateFormatter).string(from: d)
    }

    /// File size for the Size column, in the format chosen in Settings.
    static func size(_ v: Int64) -> String {
        switch Settings.sizeFormat {
        case .bytes: return int(v)
        case .kilobytes: return kb(v) + " k"
        case .dynamic: return bytes(v)
        }
    }

    static func permissions(_ mode: UInt16, isDir: Bool, isLink: Bool) -> String {
        var s = isLink ? "l" : (isDir ? "d" : "-")
        let bits: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        for (bit, ch) in bits {
            s.append(mode & bit != 0 ? ch : "-")
        }
        return s
    }
}

extension URL {
    var isExistingDirectory: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Path with the home directory shortened to "~".
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Thread-safe cancellation flag shared between UI and worker threads.
final class CancelFlag {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Filename mask matching in Total Commander style:
/// - several masks separated by ";" or spaces ("*.txt *.md"); quote names containing spaces
/// - everything after "|" is an exclusion list ("*.*|*.bak *.tmp")
/// - "*" and "?" are the only wildcards; "*.*" matches every name; "*." matches names without an extension
/// - a mask without wildcards matches as a substring
/// - case-insensitive for all languages, and insensitive to Unicode normalization (NFC vs NFD)
struct FileMask {
    let include: [String]
    let exclude: [String]

    /// The include masks, for messages.
    var patterns: [String] { include }

    init(_ text: String) {
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        include = Self.tokens(parts.first ?? "")
        exclude = parts.count > 1 ? Self.tokens(parts[1]) : []
    }

    private static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for ch in text {
            if ch == "\"" {
                quoted.toggle()
            } else if !quoted && (ch == ";" || ch == " " || ch == "\t") {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.map { p in
            if p == "*.*" { return "*" }
            if !p.contains("*") && !p.contains("?") { return "*\(p)*" }
            return p
        }
    }

    var matchesEverything: Bool { exclude.isEmpty && (include.isEmpty || include.contains("*")) }

    func matches(_ name: String, caseSensitive: Bool = false) -> Bool {
        let n = Self.normalize(name, caseSensitive)
        let included = include.isEmpty || include.contains { Self.glob(Self.normalize($0, caseSensitive), n) }
        return included && !exclude.contains { Self.glob(Self.normalize($0, caseSensitive), n) }
    }

    private static func normalize(_ s: String, _ caseSensitive: Bool) -> [Character] {
        let n = s.precomposedStringWithCanonicalMapping
        return Array(caseSensitive ? n : n.lowercased())
    }

    /// Glob with "*" and "?" over characters (not bytes).
    private static func glob(_ p: [Character], _ n: [Character]) -> Bool {
        if p == ["*", "."] { return !n.dropFirst().contains(".") }
        var pi = 0, ni = 0
        var star = -1, mark = 0
        while ni < n.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == n[ni]) {
                pi += 1
                ni += 1
            } else if pi < p.count && p[pi] == "*" {
                star = pi
                mark = ni
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ni = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
