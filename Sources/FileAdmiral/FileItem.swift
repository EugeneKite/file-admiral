import Foundation
import Darwin

/// One row of a file panel.
final class FileItem {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isParent: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let isPackage: Bool
    let size: Int64
    let modified: Date
    let mode: UInt16
    let baseName: String
    let ext: String
    /// Volume and inode (0 for remote items): two paths with the same identity are the same file.
    let device: Int
    let inode: UInt64
    /// Recursively calculated size of a directory (Space / Calculate Size).
    var dirSize: Int64?
    /// Finder tags (read from the file's metadata when listed).
    var tags: [FinderTag] = []

    /// A directory the panel navigates into on Enter (packages like .app are launched instead).
    var isFolder: Bool { isDirectory && !isPackage }

    /// Size used for sorting and status totals.
    var effectiveSize: Int64 { isDirectory ? (dirSize ?? 0) : size }

    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "prefpane", "xcodeproj", "xcworkspace",
        "playground", "photoslibrary", "rtfd", "pages", "numbers", "key", "scptd", "qlgenerator",
        "appex", "mdimporter", "saver", "xpc", "dsym", "musiclibrary", "tvlibrary", "photolibrary",
        "lpdf", "xcarchive", "imovielibrary", "fcpbundle", "logicx", "band",
    ]

    static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar", "jar", "iso", "xar", "cpio", "lzma", "zst",
    ]

    var isArchive: Bool {
        !isDirectory && FileItem.archiveExtensions.contains(ext.lowercased())
    }

    init(url: URL, name: String, isDirectory: Bool, isParent: Bool, isSymlink: Bool, isHidden: Bool,
         isPackage: Bool, size: Int64, modified: Date, mode: UInt16, device: Int = 0, inode: UInt64 = 0) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isParent = isParent
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.isPackage = isPackage
        self.size = size
        self.modified = modified
        self.mode = mode
        self.device = device
        self.inode = inode
        if isParent || (isDirectory && !isPackage) {
            baseName = name
            ext = ""
        } else if let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex {
            baseName = String(name[..<dot])
            ext = String(name[name.index(after: dot)...])
        } else {
            baseName = name
            ext = ""
        }
    }

    static func make(_ url: URL, name: String? = nil) -> FileItem? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let type = st.st_mode & 0o170000
        let isLink = type == 0o120000
        var isDir = type == 0o040000
        var size = Int64(st.st_size)
        if isLink {
            var target = stat()
            if stat(url.path, &target) == 0 {
                isDir = (target.st_mode & 0o170000) == 0o040000
                if !isDir { size = Int64(target.st_size) }
            }
        }
        let n = name ?? url.lastPathComponent
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        let hidden = n.hasPrefix(".") || (st.st_flags & 0x8000) != 0 // UF_HIDDEN
        let ext = (n as NSString).pathExtension.lowercased()
        let package = isDir && packageExtensions.contains(ext)
        let item = FileItem(url: url, name: n, isDirectory: isDir, isParent: false, isSymlink: isLink, isHidden: hidden,
                            isPackage: package, size: isDir ? 0 : size, modified: mtime, mode: st.st_mode & 0o7777,
                            device: Int(st.st_dev), inode: UInt64(st.st_ino))
        item.tags = FinderTags.read(url.path)
        return item
    }

    static func parent(of dir: URL) -> FileItem {
        let parentURL = dir.deletingLastPathComponent()
        var st = stat()
        let ok = stat(parentURL.path, &st) == 0
        let mtime = ok ? Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)) : Date()
        return FileItem(url: parentURL, name: "..", isDirectory: true, isParent: true, isSymlink: false, isHidden: false,
                        isPackage: false, size: 0, modified: mtime, mode: ok ? st.st_mode & 0o7777 : 0)
    }

    static func list(_ dir: URL, showHidden: Bool) throws -> [FileItem] {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        var out: [FileItem] = []
        out.reserveCapacity(names.count)
        for n in names {
            guard let item = make(dir.appendingPathComponent(n), name: n) else { continue }
            if !showHidden && item.isHidden { continue }
            out.append(item)
        }
        return out
    }

    static func directorySize(_ url: URL, cancel: CancelFlag? = nil) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                      errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en {
            if cancel?.isCancelled == true { break }
            if let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }

    /// Size of a file or a whole directory tree (symlinks count as 0).
    static func totalSize(of url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        switch st.st_mode & 0o170000 {
        case 0o040000: return directorySize(url)
        case 0o100000: return Int64(st.st_size)
        default: return 0
        }
    }
}

/// True if both paths point to the same inode (e.g. a case-only rename on APFS).
func isSameFile(_ a: URL, _ b: URL) -> Bool {
    var sa = stat(), sb = stat()
    guard lstat(a.path, &sa) == 0, lstat(b.path, &sb) == 0 else { return false }
    return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
}

func pathExists(_ url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0
}

/// Device number of the volume `url` is on (nil when it can't be read).
func volumeDevice(of url: URL) -> Int? {
    var st = stat()
    return stat(url.path, &st) == 0 ? Int(st.st_dev) : nil
}

/// The folder where macOS firmlinks the data volume into the system volume: walking into it from "/"
/// visits every user file a second time under /System/Volumes/Data.
let dataVolumeFirmlink = "/System/Volumes/Data"
