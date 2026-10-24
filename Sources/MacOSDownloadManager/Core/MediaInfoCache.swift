import Foundation

/// Results of reading video pages with yt-dlp (which takes a few seconds), kept for a while so that:
/// - the quality list appears at once when the page was read in the background ("prefetch", started by
///   the browser extension while a YouTube video is open);
/// - the download starts without reading the page a second time.
/// Two requests for the same video share one yt-dlp run.
actor MediaInfoCache {
    static let shared = MediaInfoCache()

    private struct Entry {
        let info: YTDLInfo
        let time: Date
    }

    private var entries: [String: Entry] = [:]
    private var running: [String: Task<YTDLInfo, Error>] = [:]
    private var prefetching = 0

    /// Stream links stay valid for hours; the list is reused for this long.
    static let defaultMaxAge: TimeInterval = 20 * 60

    /// The same video under different addresses (playlist, start time, youtu.be, shorts…) gets one key.
    static func key(for url: URL, cookies: String) -> String {
        let host = (url.host ?? "").lowercased()
        var id: String?
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            id = url.pathComponents.dropFirst().first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            let parts = url.pathComponents
            if parts.count >= 3, ["shorts", "live", "embed"].contains(parts[1]) {
                id = parts[2]
            } else {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            }
        }
        if let id, !id.isEmpty { return "youtube:\(id)|\(cookies)" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return (components?.string ?? url.absoluteString) + "|" + cookies
    }

    /// The video's formats: from the cache when younger than `maxAge`, else read now (or wait for a
    /// reading already in progress). `maxAge` 0 always reads the page again.
    func info(for url: URL, cookies: String, maxAge: TimeInterval = MediaInfoCache.defaultMaxAge) async throws -> YTDLInfo {
        let key = Self.key(for: url, cookies: cookies)
        if maxAge > 0, let entry = entries[key], Date().timeIntervalSince(entry.time) < maxAge {
            return entry.info
        }
        if let task = running[key] {
            return try await task.value
        }
        let task = Task<YTDLInfo, Error> {
            try await MediaTools.shared.extract(url: url, cookiesBrowser: cookies)
        }
        running[key] = task
        defer { running[key] = nil }
        let info = try await task.value
        store(info, key: key)
        return info
    }

    func cached(_ url: URL, cookies: String, maxAge: TimeInterval = MediaInfoCache.defaultMaxAge) -> YTDLInfo? {
        guard let entry = entries[Self.key(for: url, cookies: cookies)], Date().timeIntervalSince(entry.time) < maxAge else { return nil }
        return entry.info
    }

    /// Reads the page in the background if it is not known yet (at most two at a time).
    func prefetch(_ url: URL, cookies: String) {
        let key = Self.key(for: url, cookies: cookies)
        if let entry = entries[key], Date().timeIntervalSince(entry.time) < Self.defaultMaxAge { return }
        guard running[key] == nil, prefetching < 2 else { return }
        prefetching += 1
        Task {
            _ = try? await self.info(for: url, cookies: cookies)
            self.prefetchDone()
        }
    }

    private func prefetchDone() {
        prefetching = max(0, prefetching - 1)
    }

    private func store(_ info: YTDLInfo, key: String) {
        entries[key] = Entry(info: info, time: Date())
        // Keep the cache small: forget expired entries.
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.time) < Self.defaultMaxAge }
    }
}
