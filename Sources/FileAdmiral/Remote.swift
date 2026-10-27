import Foundation
import Darwin

/// One entry of a remote folder listing.
struct RemoteEntry {
    let name: String
    let isDirectory: Bool
    let isLink: Bool
    let size: Int64
    let modified: Date
    let mode: UInt16
}

struct RemoteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A remote file system used by a panel. All methods block and must be called off the main thread.
protocol RemoteFileSystem: AnyObject {
    /// "sftp" or "ftp"
    var scheme: String { get }
    /// "user@host" (plus port when not the default)
    var authority: String { get }
    /// Folder shown after connecting.
    var initialPath: String { get }

    func list(_ path: String) throws -> [RemoteEntry]
    /// Downloads a file or folder (recursively) to `local`, which must not exist yet.
    func download(_ remote: String, isDirectory: Bool, to local: URL) throws
    /// Uploads a local file or folder (recursively) to the remote path `remote`.
    func upload(_ local: URL, to remote: String) throws
    func delete(_ remote: String, isDirectory: Bool) throws
    func makeDirectory(_ remote: String) throws
    func rename(_ from: String, to: String) throws
    /// Aborts the command that is currently running (Cancel in a progress sheet).
    func cancelCurrent()
    func close()
}

extension RemoteFileSystem {
    /// URL used for panel items and tab state: scheme://authority/path (never a file: URL, so no local
    /// file API can ever act on a remote item by accident).
    func url(for path: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.percentEncodedHost = nil
        c.host = "remote"
        c.path = path.isEmpty ? "/" : path
        return c.url ?? URL(string: "\(scheme)://remote/")!
    }

    var title: String { "\(scheme)://\(authority)" }
}

enum RemotePath {
    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
}

/// Runs a process to completion, collecting output. Cancellable through `terminate()`.
final class ProcessRunner {
    private let lock = NSLock()
    private var current: Process?

    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    func run(_ executable: String, _ args: [String], input: String? = nil, environment: [String: String]? = nil,
             timeout: TimeInterval? = nil) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let environment { p.environment = environment }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        try p.run()
        lock.lock(); current = p; lock.unlock()
        defer { lock.lock(); current = nil; lock.unlock() }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        var timer: DispatchSourceTimer?
        if let timeout {
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now() + timeout)
            t.setEventHandler { if p.isRunning { p.terminate() } }
            t.resume()
            timer = t
        }
        // Read both pipes concurrently so neither can fill up and block the process.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        timer?.cancel()
        return Result(status: p.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
    }

    func terminate() {
        lock.lock()
        let p = current
        lock.unlock()
        if p?.isRunning == true { p?.terminate() }
    }
}

// MARK: - Listing parsers

enum ListingParser {
    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = posix
        f.dateFormat = format
        return f
    }

    private static let recent = formatter("MMM d HH:mm yyyy")
    private static let older = formatter("MMM d yyyy")
    private static let dos = formatter("MM-dd-yy hh:mma")
    private static let mlsd: DateFormatter = {
        let f = formatter("yyyyMMddHHmmss")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// A listing entry that could leave its folder ("..", "a/b") is dropped: downloads build local paths
    /// from these names, so a hostile server must not be able to write outside the destination.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    static func mode(_ perms: Substring) -> UInt16 {
        let chars = Array(perms.dropFirst().prefix(9))
        var m: UInt16 = 0
        for (i, ch) in chars.enumerated() where ch != "-" && ch != "S" && ch != "T" {
            m |= 1 << UInt16(8 - i)
        }
        return m
    }

    /// Unix `ls -l` style lines, as printed by sftp and most FTP servers:
    /// "drwxr-xr-x    2 user  group      4096 Oct 25 21:59 name"
    static func unixLine(_ line: Substring) -> RemoteEntry? {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard parts.count == 9, let type = parts[0].first, "-dlbcps".contains(type),
              let size = Int64(parts[4]) else { return nil }
        var name = String(parts[8])
        let isLink = type == "l"
        if isLink, let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        guard isSafeName(name) else { return nil }
        let dateText = "\(parts[5]) \(parts[6])"
        var date = Date.distantPast
        if parts[7].contains(":") {
            let year = Calendar.current.component(.year, from: Date())
            if let d = recent.date(from: "\(dateText) \(parts[7]) \(year)") {
                // "Recent" listings omit the year; a date in the future belongs to last year.
                date = d > Date().addingTimeInterval(86_400)
                    ? recent.date(from: "\(dateText) \(parts[7]) \(year - 1)") ?? d : d
            }
        } else {
            date = older.date(from: "\(dateText) \(parts[7])") ?? .distantPast
        }
        return RemoteEntry(name: name, isDirectory: type == "d", isLink: isLink, size: size, modified: date,
                           mode: mode(parts[0]))
    }

    /// Windows/IIS style: "10-25-26  09:59PM       <DIR>          name" or "...   1234 name"
    static func dosLine(_ line: Substring) -> RemoteEntry? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, let date = dos.date(from: "\(parts[0]) \(parts[1])"), isSafeName(String(parts[3])) else { return nil }
        let isDir = parts[2] == "<DIR>"
        return RemoteEntry(name: String(parts[3]), isDirectory: isDir, isLink: false,
                           size: isDir ? 0 : Int64(parts[2]) ?? 0, modified: date, mode: 0)
    }

    /// RFC 3659 MLSD: "type=file;size=1234;modify=20261025215900;UNIX.mode=0644; name"
    static func mlsdLine(_ line: Substring) -> RemoteEntry? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let name = String(line[line.index(after: space)...])
        var facts: [String: String] = [:]
        for f in line[..<space].split(separator: ";") {
            let kv = f.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { facts[kv[0].lowercased()] = String(kv[1]) }
        }
        let type = facts["type"]?.lowercased() ?? "file"
        if type == "cdir" || type == "pdir" || !isSafeName(name) { return nil }
        let modified = facts["modify"].flatMap { mlsd.date(from: String($0.prefix(14))) } ?? .distantPast
        let mode = facts["unix.mode"].flatMap { UInt16($0, radix: 8) } ?? 0
        return RemoteEntry(name: name, isDirectory: type == "dir", isLink: type.hasPrefix("os.unix=slink"),
                           size: Int64(facts["size"] ?? "") ?? 0, modified: modified, mode: mode & 0o777)
    }

    static func parse(_ text: String, mlsd: Bool) -> [RemoteEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            mlsd ? mlsdLine(line) : (unixLine(line) ?? dosLine(line))
        }
    }
}

// MARK: - SFTP (OpenSSH)

/// SFTP through the system OpenSSH client. One master connection authenticates once
/// (password or key passphrase via a private askpass helper); every command reuses it.
final class SFTPFileSystem: RemoteFileSystem {
    let scheme = "sftp"
    let host: String
    let port: Int
    let user: String
    private let password: String
    private let keyFile: String?
    private(set) var initialPath = "/"
    private let workDir: String
    private var master: Process?
    private let runner = ProcessRunner()

    var authority: String { port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }
    private var socket: String { workDir + "/s" }
    private var target: String { "\(user)@\(host)" }

    init(host: String, port: Int, user: String, password: String, keyFile: String?, initialPath: String?) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.keyFile = keyFile?.isEmpty == false ? (keyFile! as NSString).expandingTildeInPath : nil
        // Unix socket paths are limited to 104 bytes, so use a short private folder in /tmp.
        workDir = "/tmp/fileadmiral-\(getuid())-\(UUID().uuidString.prefix(8))"
        if let initialPath, !initialPath.isEmpty { self.initialPath = initialPath }
    }

    private var sshOptions: [String] {
        var o = ["-o", "ControlPath=\(socket)", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=20",
                 "-o", "ServerAliveInterval=30", "-o", "NumberOfPasswordPrompts=1"]
        if let keyFile { o += ["-o", "IdentityFile=\(keyFile)", "-o", "IdentitiesOnly=yes"] }
        if let knownHosts = ProcessInfo.processInfo.environment["FA_KNOWN_HOSTS"] { o += ["-o", "UserKnownHostsFile=\(knownHosts)"] }
        return o
    }

    func connect() throws {
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // The helper prints the secret from its environment; it is only ever passed to our own ssh process.
        let askpass = workDir + "/askpass"
        try "#!/bin/sh\nprintf '%s\\n' \"$FA_SSH_SECRET\"\n".write(toFile: askpass, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass)

        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpass
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env["FA_SSH_SECRET"] = password

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-M", "-N", "-p", "\(port)", "-o", "ControlPersist=no"] + sshOptions + [target]
        p.environment = env
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        master = p

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !p.isRunning {
                let text = String(decoding: err.fileHandleForReading.availableData, as: UTF8.self)
                throw RemoteError(message: Self.cleanError(text, fallback: "Connection to \(host) failed."))
            }
            if FileManager.default.fileExists(atPath: socket),
               let r = try? runner.run("/usr/bin/ssh", ["-S", socket, "-O", "check", target]), r.status == 0 {
                break
            }
            usleep(150_000)
        }
        guard p.isRunning else { throw RemoteError(message: "Connection to \(host) failed.") }
        if !FileManager.default.fileExists(atPath: socket) {
            close()
            throw RemoteError(message: "Timed out connecting to \(host).")
        }
        if initialPath == "/" {
            let out = try batch(["pwd"])
            if let line = out.split(separator: "\n").first(where: { $0.hasPrefix("Remote working directory: ") }) {
                initialPath = String(line.dropFirst("Remote working directory: ".count))
            }
        }
    }

    private static func cleanError(_ text: String, fallback: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("Warning: Permanently added") && !$0.isEmpty }
        return lines.isEmpty ? fallback : lines.joined(separator: "\n")
    }

    /// Quotes a path for sftp batch commands.
    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs sftp batch commands over the master connection; throws if any command fails.
    @discardableResult
    private func batch(_ commands: [String]) throws -> String {
        let args = ["-q", "-P", "\(port)", "-b", "-"] + sshOptions + ["-o", "ControlMaster=no", target]
        let r = try runner.run("/usr/bin/sftp", args, input: commands.joined(separator: "\n") + "\n")
        let out = String(decoding: r.stdout, as: UTF8.self)
        if r.status != 0 {
            throw RemoteError(message: Self.cleanError(r.stderr, fallback: "sftp command failed (exit \(r.status))."))
        }
        return out
    }

    func list(_ path: String) throws -> [RemoteEntry] {
        // cd first so names are printed without the folder prefix.
        let out = try batch(["cd " + Self.quote(path), "ls -la"])
        return out.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("sftp>") }
            .compactMap(ListingParser.unixLine)
    }

    func download(_ remote: String, isDirectory: Bool, to local: URL) throws {
        try batch(["get -p" + (isDirectory ? " -r " : " ") + Self.quote(remote) + " " + Self.quote(local.path)])
    }

    func upload(_ local: URL, to remote: String) throws {
        try batch(["put -p" + (local.isExistingDirectory ? " -r " : " ") + Self.quote(local.path) + " " + Self.quote(remote)])
    }

    func delete(_ remote: String, isDirectory: Bool) throws {
        guard isDirectory else {
            try batch(["rm " + Self.quote(remote)])
            return
        }
        // sftp has no recursive delete: collect the tree, then remove files and folders deepest first.
        var commands: [String] = []
        func walk(_ dir: String) throws {
            for e in try list(dir) {
                let p = RemotePath.join(dir, e.name)
                if e.isDirectory { try walk(p) } else { commands.append("rm " + Self.quote(p)) }
            }
            commands.append("rmdir " + Self.quote(dir))
        }
        try walk(remote)
        try batch(commands)
    }

    func makeDirectory(_ remote: String) throws {
        try batch(["mkdir " + Self.quote(remote)])
    }

    func rename(_ from: String, to: String) throws {
        try batch(["rename " + Self.quote(from) + " " + Self.quote(to)])
    }

    func cancelCurrent() {
        runner.terminate()
    }

    func close() {
        if master?.isRunning == true {
            _ = try? runner.run("/usr/bin/ssh", ["-S", socket, "-O", "exit", target], timeout: 5)
            master?.terminate()
        }
        master = nil
        try? FileManager.default.removeItem(atPath: workDir)
    }

    deinit { close() }
}

// MARK: - FTP / FTPS (curl)

/// FTP and FTPS through the system curl. Credentials are passed on stdin (never visible in `ps`).
final class FTPFileSystem: RemoteFileSystem {
    let scheme: String
    let host: String
    let port: Int
    let user: String
    private let password: String
    private let explicitTLS: Bool
    private let allowInvalidCertificate: Bool
    private(set) var initialPath = "/"
    private let runner = ProcessRunner()
    private var supportsMLSD = true

    var authority: String { port == 21 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }

    init(host: String, port: Int, user: String, password: String, tls: Bool, allowInvalidCertificate: Bool,
         initialPath: String?) {
        scheme = tls ? "ftps" : "ftp"
        self.host = host
        self.port = port
        self.user = user.isEmpty ? "anonymous" : user
        self.password = user.isEmpty && password.isEmpty ? "anonymous@" : password
        explicitTLS = tls
        self.allowInvalidCertificate = allowInvalidCertificate
        if let initialPath, !initialPath.isEmpty { self.initialPath = initialPath }
    }

    /// curl URL for an absolute path; "%2F" makes curl start from the server root, not the login folder.
    private func curlURL(_ path: String, directory: Bool) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ";?#%"))
        let parts = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
        let host = self.host.contains(":") ? "[\(self.host)]" : self.host
        var u = "ftp://\(host):\(port)/%2F" + parts.joined(separator: "/")
        if directory && !u.hasSuffix("/") { u += "/" }
        return u
    }

    private func configEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs curl with the given extra config lines (each "option = value").
    @discardableResult
    private func curl(_ lines: [String], args: [String] = []) throws -> Data {
        var config = ["user = \"\(configEscape(user)):\(configEscape(password))\"", "silent", "show-error",
                      "connect-timeout = 20", "ftp-pasv"]
        if explicitTLS { config.append("ssl-reqd") }
        if allowInvalidCertificate { config.append("insecure") }
        config += lines
        let r = try runner.run("/usr/bin/curl", ["-K", "-"] + args, input: config.joined(separator: "\n") + "\n")
        if r.status != 0 {
            let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteError(message: msg.isEmpty ? "FTP command failed (curl exit \(r.status))." : msg)
        }
        return r.stdout
    }

    func connect() throws {
        // Ask the server for the login folder: curl prints the PWD reply in verbose mode.
        var config = ["user = \"\(configEscape(user)):\(configEscape(password))\"", "connect-timeout = 20", "ftp-pasv",
                      "verbose", "list-only", "url = \"\(curlURL("/", directory: true).replacingOccurrences(of: "/%2F", with: "/"))\""]
        if explicitTLS { config.append("ssl-reqd") }
        if allowInvalidCertificate { config.append("insecure") }
        let r = try runner.run("/usr/bin/curl", ["-K", "-", "-o", "/dev/null"], input: config.joined(separator: "\n") + "\n")
        if r.status != 0 {
            let lines = r.stderr.split(separator: "\n").filter { $0.hasPrefix("< 5") || $0.hasPrefix("curl:") }
            throw RemoteError(message: lines.isEmpty ? "Cannot connect to \(host) (curl exit \(r.status))."
                                                    : lines.map { String($0.drop { $0 == "<" || $0 == " " }) }.joined(separator: "\n"))
        }
        if initialPath == "/", let line = r.stderr.split(separator: "\n").first(where: { $0.hasPrefix("< 257 ") }),
           let start = line.firstIndex(of: "\""), let end = line[line.index(after: start)...].firstIndex(of: "\"") {
            initialPath = String(line[line.index(after: start)..<end])
        }
    }

    func list(_ path: String) throws -> [RemoteEntry] {
        if supportsMLSD {
            do {
                let data = try curl(["request = \"MLSD\"", "url = \"\(curlURL(path, directory: true))\""])
                return ListingParser.parse(String(decoding: data, as: UTF8.self), mlsd: true)
            } catch {
                supportsMLSD = false
            }
        }
        let data = try curl(["url = \"\(curlURL(path, directory: true))\""])
        return ListingParser.parse(String(decoding: data, as: UTF8.self), mlsd: false)
    }

    func download(_ remote: String, isDirectory: Bool, to local: URL) throws {
        guard isDirectory else {
            try curl(["url = \"\(curlURL(remote, directory: false))\"", "output = \"\(configEscape(local.path))\""])
            return
        }
        // Collect the tree and fetch all files in one curl run (one connection).
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        var lines: [String] = []
        func walk(_ dir: String, _ into: URL) throws {
            for e in try list(dir) {
                let p = RemotePath.join(dir, e.name)
                let dst = into.appendingPathComponent(e.name)
                if e.isDirectory {
                    try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
                    try walk(p, dst)
                } else {
                    lines += ["url = \"\(curlURL(p, directory: false))\"", "output = \"\(configEscape(dst.path))\""]
                }
            }
        }
        try walk(remote, local)
        if !lines.isEmpty { try curl(lines) }
    }

    func upload(_ local: URL, to remote: String) throws {
        guard local.isExistingDirectory else {
            try curl(["upload-file = \"\(configEscape(local.path))\"", "url = \"\(curlURL(remote, directory: false))\"",
                      "ftp-create-dirs"])
            return
        }
        try makeDirectory(remote)
        var lines: [String] = ["ftp-create-dirs"]
        var emptyDirs: [String] = []
        let base = local.standardizedFileURL.path
        let en = FileManager.default.enumerator(at: local, includingPropertiesForKeys: [.isDirectoryKey])
        while let u = en?.nextObject() as? URL {
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
            let dst = RemotePath.join(remote, rel)
            if u.isExistingDirectory {
                if (try? FileManager.default.contentsOfDirectory(atPath: u.path))?.isEmpty == true { emptyDirs.append(dst) }
            } else {
                lines += ["upload-file = \"\(configEscape(u.path))\"", "url = \"\(curlURL(dst, directory: false))\""]
            }
        }
        if lines.count > 1 { try curl(lines) }
        for d in emptyDirs { try? makeDirectory(d) }
    }

    /// Runs raw FTP commands (DELE, MKD, …) on the control connection.
    private func quote(_ commands: [String]) throws {
        try curl(commands.map { "quote = \"\(configEscape($0))\"" } + ["url = \"\(curlURL("/", directory: true))\"", "list-only"])
    }

    func delete(_ remote: String, isDirectory: Bool) throws {
        guard isDirectory else {
            try quote(["DELE \(remote)"])
            return
        }
        var commands: [String] = []
        func walk(_ dir: String) throws {
            for e in try list(dir) {
                let p = RemotePath.join(dir, e.name)
                if e.isDirectory { try walk(p) } else { commands.append("DELE \(p)") }
            }
            commands.append("RMD \(dir)")
        }
        try walk(remote)
        try quote(commands)
    }

    func makeDirectory(_ remote: String) throws {
        try quote(["MKD \(remote)"])
    }

    func rename(_ from: String, to: String) throws {
        try quote(["RNFR \(from)", "RNTO \(to)"])
    }

    func cancelCurrent() {
        runner.terminate()
    }

    func close() {}
}
