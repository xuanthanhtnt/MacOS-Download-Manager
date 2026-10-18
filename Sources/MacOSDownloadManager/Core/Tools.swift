import Foundation
import CryptoKit

// MARK: - URL probing (used by the "Download File Info" dialog)

struct ProbeResult {
    var finalURL: URL
    var totalBytes: Int64 = -1
    var resumable = false
    var fileName: String?
    var mime: String?
    var isHLS = false
    var hlsVariants: [HLSVariant] = []
    var hlsDuration: Double = 0
}

enum URLProbe {
    static func probe(url: URL, headers: [String: String], username: String?, password: String?,
                      proxy: [AnyHashable: Any]?, timeout: TimeInterval = 20) async throws -> ProbeResult {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if headers.keys.contains(where: { $0.lowercased() == "cookie" }) { cfg.httpShouldSetCookies = false }
        if let proxy { cfg.connectionProxyDictionary = proxy }
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let username, !username.isEmpty {
            request.setValue(HTTPUtils.basicAuthHeader(user: username, password: password ?? ""), forHTTPHeaderField: "Authorization")
        }

        if FileNameUtils.isHLS(url: url) {
            return try await probeHLS(url: url, request: request, session: session)
        }

        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel()

        var result = ProbeResult(finalURL: response.url ?? url)
        result.mime = response.mimeType
        if let http = response as? HTTPURLResponse {
            if http.statusCode >= 400 {
                throw NSError(domain: "MacOSDownloadManager", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: HTTPUtils.message(forStatus: http.statusCode)])
            }
            if http.statusCode == 206, let cr = HTTPUtils.parseContentRange(http.value(forHTTPHeaderField: "Content-Range")) {
                result.totalBytes = cr.total
                result.resumable = cr.total > 0
            } else {
                result.totalBytes = response.expectedContentLength
            }
            if let cd = http.value(forHTTPHeaderField: "Content-Disposition") {
                result.fileName = FileNameUtils.parseContentDisposition(cd)
            }
        } else {
            result.totalBytes = response.expectedContentLength
        }
        if result.fileName == nil {
            let finalURL = response.url ?? url
            let fromURL = FileNameUtils.nameFromURL(finalURL)
            result.fileName = FileNameUtils.ensureExtension(fromURL, mime: response.mimeType)
        }
        if FileNameUtils.isHLS(url: result.finalURL, mime: response.mimeType) {
            request.setValue(nil, forHTTPHeaderField: "Range")
            return try await probeHLS(url: result.finalURL, request: request, session: session)
        }
        return result
    }

    private static func probeHLS(url: URL, request: URLRequest, session: URLSession) async throws -> ProbeResult {
        var req = request
        req.url = url
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "MacOSDownloadManager", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: HTTPUtils.message(forStatus: http.statusCode)])
        }
        let base = response.url ?? url
        let playlist = M3U8Parser.parse(String(decoding: data, as: UTF8.self), baseURL: base)
        var result = ProbeResult(finalURL: base)
        result.isHLS = true
        result.resumable = true
        result.mime = "application/vnd.apple.mpegurl"
        result.hlsVariants = playlist.variants.sorted { $0.bandwidth > $1.bandwidth }
        result.hlsDuration = playlist.totalDuration
        var name = (FileNameUtils.nameFromURL(url) as NSString).deletingPathExtension
        if name.isEmpty || name.lowercased() == "index" || name.lowercased() == "master" || name.lowercased() == "playlist" {
            name = "video"
        }
        result.fileName = name + ".ts"
        return result
    }
}

// MARK: - Batch download (URLs with a wildcard)

enum BatchExpander {
    /// Replaces "*" in `template` with numbers or letters from `from` to `to`.
    static func expand(template: String, letters: Bool, from: String, to: String, width: Int, limit: Int = 10_000) -> [URL] {
        guard template.contains("*") else {
            return URL(string: template).map { [$0] } ?? []
        }
        var values: [String] = []
        if letters {
            guard let a = from.lowercased().unicodeScalars.first?.value,
                  let b = to.lowercased().unicodeScalars.first?.value, a <= b else { return [] }
            for v in a...b {
                if let scalar = Unicode.Scalar(v) { values.append(String(Character(scalar))) }
            }
        } else {
            guard let a = Int(from.trimmingCharacters(in: .whitespaces)),
                  let b = Int(to.trimmingCharacters(in: .whitespaces)), a <= b else { return [] }
            for v in a...min(b, a + limit - 1) {
                var s = String(v)
                if width > s.count { s = String(repeating: "0", count: width - s.count) + s }
                values.append(s)
            }
        }
        return values.prefix(limit).compactMap { URL(string: template.replacingOccurrences(of: "*", with: $0)) }
    }
}

// MARK: - Site grabber (spider)

final class SiteGrabber {
    struct Options {
        var startURL: URL
        var depth: Int
        var extensions: Set<String>
        var sameHostOnly: Bool
        var maxPages: Int
        var userAgent: String
    }

    private(set) var cancelled = false

    func cancel() { cancelled = true }

    static let pageExtensions: Set<String> = ["", "html", "htm", "php", "asp", "aspx", "jsp", "shtml", "xhtml", "cgi"]

    /// Crawls pages breadth-first and returns links to files whose extension is in `extensions`.
    func run(_ options: Options, progress: @escaping (Int, Int) -> Void) async -> [URL] {
        var visited = Set<String>()
        var found: [URL] = []
        var foundSet = Set<String>()
        var frontier: [URL] = [options.startURL]
        var pages = 0
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        for level in 0...max(0, options.depth) {
            var next: [URL] = []
            for page in frontier {
                if cancelled || Task.isCancelled || pages >= options.maxPages { break }
                let key = page.absoluteString
                if visited.contains(key) { continue }
                visited.insert(key)
                pages += 1
                guard let html = await fetchHTML(page, session: session, userAgent: options.userAgent) else { continue }
                for link in SiteGrabber.extractLinks(html, base: page) {
                    guard let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
                    if options.sameHostOnly, link.host?.lowercased() != options.startURL.host?.lowercased() { continue }
                    let ext = link.pathExtension.lowercased()
                    if options.extensions.contains(ext) {
                        if !foundSet.contains(link.absoluteString) {
                            foundSet.insert(link.absoluteString)
                            found.append(link)
                        }
                    } else if level < options.depth, SiteGrabber.pageExtensions.contains(ext) {
                        next.append(link)
                    }
                }
                let p = pages, f = found.count
                progress(p, f)
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return found
    }

    private func fetchHTML(_ url: URL, session: URLSession, userAgent: String) async -> String? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let result = try? await session.data(for: req) else { return nil }
        let (data, response) = result
        if let mime = response.mimeType?.lowercased(), !mime.contains("html") && !mime.contains("xml") { return nil }
        return String(decoding: data.prefix(5_000_000), as: UTF8.self)
    }

    private static let linkRegex = try? NSRegularExpression(
        pattern: #"(?:href|src)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
        options: [.caseInsensitive])

    static func extractLinks(_ html: String, base: URL) -> [URL] {
        guard let regex = linkRegex else { return [] }
        let ns = html as NSString
        var result: [URL] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            var value: String?
            for g in 1...3 {
                let r = match.range(at: g)
                if r.location != NSNotFound { value = ns.substring(with: r); break }
            }
            guard var raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            raw = raw.replacingOccurrences(of: "&amp;", with: "&")
            if raw.hasPrefix("#") || raw.lowercased().hasPrefix("javascript:") || raw.lowercased().hasPrefix("mailto:") { continue }
            if let fragment = raw.firstIndex(of: "#") { raw = String(raw[..<fragment]) }
            let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%#"))) ?? raw
            guard let url = URL(string: raw, relativeTo: base)?.absoluteURL ?? URL(string: encoded, relativeTo: base)?.absoluteURL else { continue }
            if seen.insert(url.absoluteString).inserted { result.append(url) }
        }
        return result
    }
}

// MARK: - Checksum

enum ChecksumAlgorithm: String, CaseIterable, Identifiable {
    case md5 = "MD5"
    case sha1 = "SHA-1"
    case sha256 = "SHA-256"
    case sha512 = "SHA-512"

    var id: String { rawValue }
}

enum Checksum {
    static func compute(_ algorithm: ChecksumAlgorithm, path: String, progress: @escaping (Double) -> Void) throws -> String {
        switch algorithm {
        case .md5: return try hash(Insecure.MD5.self, path: path, progress: progress)
        case .sha1: return try hash(Insecure.SHA1.self, path: path, progress: progress)
        case .sha256: return try hash(SHA256.self, path: path, progress: progress)
        case .sha512: return try hash(SHA512.self, path: path, progress: progress)
        }
    }

    private static func hash<H: HashFunction>(_ type: H.Type, path: String, progress: (Double) -> Void) throws -> String {
        var hasher = H()
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        var processed: Int64 = 0
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
            hasher.update(data: data)
            processed += Int64(data.count)
            if size > 0 { progress(Double(processed) / Double(size)) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Import / export of download lists (plain text and IDM .ef2)

enum ListFormat {
    static func exportText(_ items: [DownloadItem]) -> String {
        items.map(\.url.absoluteString).joined(separator: "\n") + "\n"
    }

    static func exportEF2(_ items: [DownloadItem]) -> String {
        var out = ""
        for item in items {
            out += "<\r\n\(item.url.absoluteString)\r\n"
            if let referer = item.referer, !referer.isEmpty { out += "referer: \(referer)\r\n" }
            if let ua = item.userAgent, !ua.isEmpty { out += "User-Agent: \(ua)\r\n" }
            if let cookie = item.cookies, !cookie.isEmpty { out += "cookie: \(cookie)\r\n" }
            out += ">\r\n"
        }
        return out
    }

    static func parse(_ text: String) -> [CaptureRequest] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [CaptureRequest] = []
        if lines.contains("<") {
            var current: CaptureRequest?
            for line in lines {
                if line == "<" {
                    current = nil
                } else if line == ">" {
                    if let c = current { result.append(c) }
                    current = nil
                } else if current == nil, let url = URL(string: line), url.scheme != nil {
                    current = CaptureRequest(url: url)
                } else if let colon = line.firstIndex(of: ":"), current != nil {
                    let key = line[..<colon].lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "referer": current?.referer = value
                    case "user-agent": current?.userAgent = value
                    case "cookie": current?.cookies = value
                    case "username": current?.username = value
                    case "password": current?.password = value
                    default: break
                    }
                }
            }
            if let c = current { result.append(c) }
        } else {
            for line in lines where !line.isEmpty && !line.hasPrefix("#") {
                if let url = URL(string: line), let scheme = url.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme) {
                    result.append(CaptureRequest(url: url))
                }
            }
        }
        return result
    }
}
