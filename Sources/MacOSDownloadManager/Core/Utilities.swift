import Foundation
import Security
import UniformTypeIdentifiers

// MARK: - Formatting

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        guard value >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let s = Int(seconds.rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 99 { return "∞" }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        return dateFormatter.string(from: date)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

// MARK: - File names

enum FileNameUtils {
    /// Extracts the file name from a Content-Disposition header value.
    static func parseContentDisposition(_ header: String) -> String? {
        let parts = header.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var plain: String?
        for part in parts {
            let lower = part.lowercased()
            if lower.hasPrefix("filename*=") {
                var value = String(part.dropFirst("filename*=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if let range = value.range(of: "''") {
                    value = String(value[range.upperBound...])
                }
                if let decoded = value.removingPercentEncoding, !decoded.isEmpty {
                    return sanitize(decoded)
                }
            } else if lower.hasPrefix("filename=") {
                var value = String(part.dropFirst("filename=".count)).trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                plain = value
            }
        }
        if let plain, !plain.isEmpty {
            let fixed = fixLatin1(plain)
            return sanitize(fixed.removingPercentEncoding ?? fixed)
        }
        return nil
    }

    /// Header values are decoded as ISO-8859-1; servers often send raw UTF-8 bytes. Recover them.
    static func fixLatin1(_ value: String) -> String {
        guard value.unicodeScalars.allSatisfy({ $0.value <= 0xFF }),
              value.unicodeScalars.contains(where: { $0.value >= 0x80 }),
              let data = value.data(using: .isoLatin1),
              let utf8 = String(data: data, encoding: .utf8) else {
            return value
        }
        return utf8
    }

    static func nameFromURL(_ url: URL) -> String {
        var name = url.lastPathComponent
        if name.isEmpty || name == "/" {
            name = url.host ?? "download"
        }
        name = name.removingPercentEncoding ?? name
        let cleaned = sanitize(name)
        return cleaned.isEmpty ? "download" : cleaned
    }

    static func sanitize(_ name: String) -> String {
        var result = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        if result.count > 240 {
            let ext = (result as NSString).pathExtension
            let base = (result as NSString).deletingPathExtension
            result = String(base.prefix(200)) + (ext.isEmpty ? "" : "." + ext)
        }
        return result
    }

    /// Characters Windows file systems refuse in names, replaced by full-width look-alikes (as yt-dlp
    /// does) so titles such as "Song | Artist" stay readable.
    private static let windowsReplacements: [Character: Character] = [
        "\\": "＼", "*": "＊", "?": "？", "\"": "＂", "<": "＜", ">": "＞", "|": "｜"
    ]
    private static let windowsReservedNames: Set<String> = Set(["CON", "PRN", "AUX", "NUL"]
        + (1...9).map { "COM\($0)" } + (1...9).map { "LPT\($0)" })

    /// Makes `name` valid on NTFS, exFAT and FAT32: no reserved characters, no trailing dot or space,
    /// no device name such as "CON".
    static func windowsSafe(_ name: String) -> String {
        var result = String(name.map { c -> Character in
            if let replacement = windowsReplacements[c] { return replacement }
            return c.unicodeScalars.contains { $0.value < 0x20 } ? " " : c
        })
        while let last = result.last, last == "." || last == " " { result.removeLast() }
        let stem = result.split(separator: ".", maxSplits: 1).first.map(String.init) ?? result
        if windowsReservedNames.contains(stem.trimmingCharacters(in: .whitespaces).uppercased()) {
            result = "_" + result
        }
        return result
    }

    /// The name to save `name` under in `directory`: drives that are not formatted by Apple (NTFS,
    /// exFAT, FAT32, network shares…) refuse some names macOS accepts, e.g. "a | b.mp4".
    /// The name is also decomposed (NFD), the form FileManager uses: FAT32 only renames a file when
    /// it is given in the form it was created with, and yt-dlp/ffmpeg create files with the form they get.
    static func fileName(_ name: String, forDirectory directory: String) -> String {
        guard VolumeUtils.needsWindowsNames(directory) else { return name }
        return windowsSafe(name).decomposedStringWithCanonicalMapping
    }

    /// Opens `path` for reading and writing, creating it when missing. The error says what is wrong
    /// (a name the drive refuses, a read-only drive…) instead of a generic "no permission".
    static func openForUpdating(_ path: String) throws -> FileHandle {
        let fd = URL(fileURLWithPath: path).withUnsafeFileSystemRepresentation { rep -> Int32 in
            guard let rep else { errno = EINVAL; return -1 }
            return open(rep, O_RDWR | O_CREAT, 0o666)
        }
        guard fd >= 0 else { throw fileError(errno) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func fileError(_ code: Int32) -> Error {
        let message: String
        switch code {
        case EINVAL, EILSEQ:
            message = String(localized: "The drive does not accept this file name. Rename the download, then click Resume.")
        case EROFS:
            message = String(localized: "The drive is read-only. macOS cannot write to NTFS drives without an NTFS driver: choose another folder or install one.")
        default:
            return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Appends an extension derived from the MIME type when the name has none.
    static func ensureExtension(_ name: String, mime: String?) -> String {
        guard (name as NSString).pathExtension.isEmpty,
              let mime, !mime.isEmpty,
              let type = UTType(mimeType: mime),
              let ext = type.preferredFilenameExtension else {
            return name
        }
        return name + "." + ext
    }

    /// Returns a path in `directory` that does not collide with an existing file
    /// (or an unfinished `.mdmpart` file), e.g. "name (1).zip".
    static func uniquePath(directory: String, fileName: String, reserved: Set<String> = []) -> String {
        let fm = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = (directory as NSString).appendingPathComponent(fileName)
        var n = 1
        while fm.fileExists(atPath: candidate) || fm.fileExists(atPath: candidate + ".mdmpart") || reserved.contains(candidate) {
            let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = (directory as NSString).appendingPathComponent(newName)
            n += 1
        }
        return candidate
    }

    static func isHLS(url: URL, mime: String? = nil) -> Bool {
        if url.pathExtension.lowercased() == "m3u8" { return true }
        if let mime = mime?.lowercased(), mime.contains("mpegurl") { return true }
        return false
    }
}

// MARK: - Volumes

enum VolumeUtils {
    /// File system of the volume holding `path` ("apfs", "hfs", "exfat", "msdos", "ntfs", "macfuse",
    /// "smbfs"…). A folder that does not exist yet is looked up through its nearest existing parent.
    static func fileSystemType(_ path: String) -> String? {
        var current = path
        while !current.isEmpty {
            var info = statfs()
            if statfs(current, &info) == 0 {
                return withUnsafeBytes(of: info.f_fstypename) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }.lowercased()
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    /// Only Apple's own file systems accept every name macOS does.
    static func needsWindowsNames(_ directory: String) -> Bool {
        guard let type = fileSystemType(directory) else { return false }
        return type != "apfs" && type != "hfs"
    }

    /// Largest file the volume can hold: FAT32 (msdos) stops just under 4 GB.
    static func maxFileSize(_ directory: String) -> Int64? {
        fileSystemType(directory) == "msdos" ? 0xFFFF_FFFF : nil
    }
}

// MARK: - HTTP helpers

enum HTTPUtils {
    struct ContentRange {
        var start: Int64
        var end: Int64
        var total: Int64
    }

    /// Parses "bytes 0-1023/146515" (total may be "*").
    static func parseContentRange(_ value: String?) -> ContentRange? {
        guard var s = value?.trimmingCharacters(in: .whitespaces).lowercased(), s.hasPrefix("bytes") else {
            return nil
        }
        s = String(s.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: " ="))
        let parts = s.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let range = parts[0].split(separator: "-")
        guard range.count == 2,
              let a = Int64(range[0].trimmingCharacters(in: .whitespaces)),
              let b = Int64(range[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let total = Int64(parts[1].trimmingCharacters(in: .whitespaces)) ?? -1
        return ContentRange(start: a, end: b, total: total)
    }

    static func message(forStatus status: Int) -> String {
        switch status {
        case 401: return String(localized: "Authorization required (HTTP 401)")
        case 403: return String(localized: "Access denied (HTTP 403). The link may have expired — try “Refresh download address”.")
        case 404: return String(localized: "File not found (HTTP 404)")
        case 410: return String(localized: "File is no longer available (HTTP 410)")
        case 416: return String(localized: "Requested range not satisfiable (HTTP 416)")
        case 429: return String(localized: "Too many requests (HTTP 429)")
        default:
            return String(format: NSLocalizedString("Server error (HTTP %d)", comment: ""), status)
        }
    }

    static func basicAuthHeader(user: String, password: String) -> String {
        let token = Data("\(user):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }
}

// MARK: - Speed limiter (global token bucket shared by all downloads)

final class SpeedLimiter {
    static let shared = SpeedLimiter()

    private let lock = NSLock()
    private var bytesPerSecond: Double = 0
    private var tokens: Double = 0
    private var last = Date()

    /// 0 disables the limiter.
    func setLimit(bytesPerSecond value: Int64) {
        lock.lock()
        bytesPerSecond = Double(max(0, value))
        tokens = bytesPerSecond
        last = Date()
        lock.unlock()
    }

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return bytesPerSecond > 0
    }

    /// Consumes `count` bytes and returns how long the caller should wait before reading more.
    func consume(_ count: Int) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard bytesPerSecond > 0 else { return 0 }
        let now = Date()
        let elapsed = now.timeIntervalSince(last)
        last = now
        tokens = min(bytesPerSecond, tokens + elapsed * bytesPerSecond)
        tokens -= Double(count)
        if tokens >= 0 { return 0 }
        return -tokens / bytesPerSecond
    }
}

/// Measures throughput over a short sliding window. Not thread-safe: use from one queue.
struct SpeedMeter {
    private var buckets: [Int64] = []
    private var pending: Int64 = 0
    private let interval: Double
    private let window: Int

    init(interval: Double = 0.5, window: Int = 6) {
        self.interval = interval
        self.window = window
    }

    mutating func add(_ bytes: Int) {
        pending += Int64(bytes)
    }

    /// Call once per `interval`; returns the current speed in bytes per second.
    mutating func tick() -> Double {
        buckets.append(pending)
        pending = 0
        if buckets.count > window { buckets.removeFirst(buckets.count - window) }
        let sum = buckets.reduce(0, +)
        return Double(sum) / (Double(buckets.count) * interval)
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "io.github.xuanthanhtnt.MacOSDownloadManager"

    static func set(_ password: String, account: String) {
        delete(account: account)
        guard !password.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
