import Foundation
import CommonCrypto

// MARK: - M3U8 model & parser

struct HLSVariant: Identifiable, Hashable {
    var id: URL { url }
    var url: URL
    var bandwidth: Int
    var resolution: String?
    var codecs: String?
    var hasSeparateAudio: Bool

    var title: String {
        var parts: [String] = []
        if let resolution { parts.append(resolution) }
        if bandwidth > 0 { parts.append(String(format: "%.1f Mbps", Double(bandwidth) / 1_000_000)) }
        if hasSeparateAudio { parts.append(String(localized: "(separate audio)")) }
        return parts.isEmpty ? url.lastPathComponent : parts.joined(separator: " · ")
    }
}

struct HLSKey: Hashable {
    var method: String
    var uri: URL?
    var iv: Data?
}

struct HLSSegment {
    var index: Int
    var url: URL
    var duration: Double
    var key: HLSKey?
    var sequence: Int
    var byteRange: (length: Int64, offset: Int64)?
}

struct HLSPlaylist {
    var isMaster = false
    var variants: [HLSVariant] = []
    var segments: [HLSSegment] = []
    var mapURL: URL?
    var mapRange: (length: Int64, offset: Int64)?
    var endList = false
    var mediaSequence = 0

    var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// Highest quality variant, preferring variants whose audio is muxed into the video stream.
    var bestVariant: HLSVariant? {
        let muxed = variants.filter { !$0.hasSeparateAudio }
        let pool = muxed.isEmpty ? variants : muxed
        return pool.max { $0.bandwidth < $1.bandwidth }
    }
}

enum M3U8Parser {
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var inQuotes = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces).uppercased()
            if !k.isEmpty { result[k] = value.trimmingCharacters(in: .whitespaces) }
            key = ""
            value = ""
            inKey = true
        }
        for ch in text {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { flush() } else { key.append(ch) }
            } else {
                if ch == "\"" {
                    inQuotes.toggle()
                } else if ch == "," && !inQuotes {
                    flush()
                } else {
                    value.append(ch)
                }
            }
        }
        flush()
        return result
    }

    static func parseByteRange(_ text: String) -> (Int64, Int64?)? {
        let parts = text.split(separator: "@")
        guard let length = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let offset = parts.count > 1 ? Int64(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (length, offset)
    }

    static func hexData(_ text: String) -> Data? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.lowercased().hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func parse(_ text: String, baseURL: URL) -> HLSPlaylist {
        var playlist = HLSPlaylist()
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var audioGroupsWithURI = Set<String>()
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            let attrs = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            if attrs["TYPE"] == "AUDIO", attrs["URI"] != nil, let group = attrs["GROUP-ID"] {
                audioGroupsWithURI.insert(group)
            }
        }

        var pendingStreamInf: [String: String]?
        var currentKey: HLSKey?
        var duration: Double = 0
        var pendingRange: (Int64, Int64?)?
        var lastRangeEnd: Int64 = 0
        var sequence = 0
        var index = 0

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                playlist.isMaster = true
                pendingStreamInf = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                playlist.mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
                sequence = playlist.mediaSequence
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = attrs["METHOD"] ?? "NONE"
                if method == "NONE" {
                    currentKey = nil
                } else {
                    let uri = attrs["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
                    currentKey = HLSKey(method: method, uri: uri, iv: attrs["IV"].flatMap(hexData))
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                playlist.mapURL = attrs["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
                if let br = attrs["BYTERANGE"], let r = parseByteRange(br) {
                    playlist.mapRange = (r.0, r.1 ?? 0)
                }
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                duration = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = parseByteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                playlist.endList = true
            } else if line.hasPrefix("#") {
                continue
            } else if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                if let inf = pendingStreamInf {
                    let audioGroup = inf["AUDIO"]
                    let variant = HLSVariant(url: url,
                                             bandwidth: Int(inf["BANDWIDTH"] ?? "") ?? 0,
                                             resolution: inf["RESOLUTION"],
                                             codecs: inf["CODECS"],
                                             hasSeparateAudio: audioGroup.map { audioGroupsWithURI.contains($0) } ?? false)
                    playlist.variants.append(variant)
                    pendingStreamInf = nil
                } else {
                    var range: (length: Int64, offset: Int64)?
                    if let r = pendingRange {
                        let offset = r.1 ?? lastRangeEnd
                        range = (r.0, offset)
                        lastRangeEnd = offset + r.0
                    }
                    playlist.segments.append(HLSSegment(index: index, url: url, duration: duration,
                                                        key: currentKey, sequence: sequence, byteRange: range))
                    index += 1
                    sequence += 1
                    duration = 0
                    pendingRange = nil
                }
            }
        }
        return playlist
    }
}

enum AES128 {
    static func decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, kCCKeySizeAES128, ivPtr.baseAddress,
                                inPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        out.count = moved
        return out
    }

    static func iv(forSequence sequence: Int) -> Data {
        var iv = Data(count: 16)
        var value = UInt64(max(0, sequence)).bigEndian
        withUnsafeBytes(of: &value) { bytes in
            iv.replaceSubrange(8..<16, with: bytes)
        }
        return iv
    }
}

// MARK: - HLS engine

/// Downloads an HLS (m3u8) video-on-demand stream: the parts are fetched in parallel,
/// AES-128 encrypted parts are decrypted, then everything is joined into one .ts/.mp4 file.
final class HLSDownloadEngine: DownloadEngine {
    var onEvent: ((EngineEvent) -> Void)?

    private let item: DownloadItem
    private let tempPath: String
    private let config: EngineConfig
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "mdm.hls.timer")

    // Guarded by `lock`
    private var done: Set<Int>
    private var segmentCount: Int
    private var bytesDone: Int64 = 0
    private var meter = SpeedMeter()
    private var speed: Double = 0
    private var active = 0
    private var stopped = false
    private var keyCache: [URL: Data] = [:]

    private var partsDirectory: String { tempPath + ".parts" }

    init(item: DownloadItem, tempPath: String, config: EngineConfig) {
        self.item = item
        self.tempPath = tempPath
        self.config = config
        self.done = Set(item.hlsDoneSegments)
        self.segmentCount = item.hlsSegmentCount
        self.bytesDone = item.downloadedBytes
    }

    func start() {
        startTimer()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        guard !already else { return }
        task?.cancel()
        stopTimer()
        let snap = snapshot()
        DispatchQueue.main.async { self.onEvent?(.stopped(snap)) }
    }

    private var isStopped: Bool {
        locked { stopped }
    }

    /// Synchronous critical section (safe to call from async code).
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = max(1, config.maxConnections)
        cfg.timeoutIntervalForRequest = config.timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        if config.headers.keys.contains(where: { $0.lowercased() == "cookie" }) {
            cfg.httpShouldSetCookies = false
        }
        if let proxy = config.proxy { cfg.connectionProxyDictionary = proxy }
        return URLSession(configuration: cfg)
    }

    private func request(_ url: URL, range: (length: Int64, offset: Int64)? = nil) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: config.timeout)
        for (k, v) in config.headers { r.setValue(v, forHTTPHeaderField: k) }
        if let cred = config.credential, let user = cred.user, let pass = cred.password {
            r.setValue(HTTPUtils.basicAuthHeader(user: user, password: pass), forHTTPHeaderField: "Authorization")
        }
        if let range {
            r.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range")
        }
        return r
    }

    private func fetch(_ session: URLSession, _ url: URL, range: (length: Int64, offset: Int64)? = nil) async throws -> Data {
        var lastError: Error = URLError(.unknown)
        for attempt in 0...max(0, config.retries) {
            if Task.isCancelled { throw CancellationError() }
            do {
                let (data, response) = try await session.data(for: request(url, range: range))
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw NSError(domain: "MacOSDownloadManager", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: HTTPUtils.message(forStatus: http.statusCode)])
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if Task.isCancelled { throw CancellationError() }
                if attempt < config.retries {
                    try await Task.sleep(nanoseconds: UInt64(min(Double(attempt + 1) * 1.5, 10) * 1_000_000_000))
                }
            }
        }
        throw lastError
    }

    private func run() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            var mediaURL = item.hlsVariantURL ?? item.url
            var playlistData = try await fetch(session, mediaURL)
            var playlist = M3U8Parser.parse(String(decoding: playlistData, as: UTF8.self), baseURL: mediaURL)
            if playlist.isMaster {
                guard let variant = playlist.bestVariant else {
                    throw NSError(domain: "MacOSDownloadManager", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "No playable stream was found in the playlist")])
                }
                mediaURL = variant.url
                playlistData = try await fetch(session, mediaURL)
                playlist = M3U8Parser.parse(String(decoding: playlistData, as: UTF8.self), baseURL: mediaURL)
            }
            guard !playlist.segments.isEmpty else {
                throw NSError(domain: "MacOSDownloadManager", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "The playlist does not contain any media segment")])
            }
            guard playlist.endList else {
                throw NSError(domain: "MacOSDownloadManager", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "Live streams are not supported (the playlist has no end)")])
            }
            for seg in playlist.segments where seg.key != nil && seg.key?.method != "AES-128" {
                throw NSError(domain: "MacOSDownloadManager", code: 4, userInfo: [NSLocalizedDescriptionKey: String(localized: "This stream uses DRM protection and cannot be downloaded")])
            }

            let count = playlist.segments.count
            locked {
                if segmentCount != count {
                    segmentCount = count
                    done = []
                    bytesDone = 0
                }
            }

            let fm = FileManager.default
            try fm.createDirectory(atPath: partsDirectory, withIntermediateDirectories: true)
            // Forget parts whose file disappeared.
            locked {
                done = done.filter { fm.fileExists(atPath: partPath($0)) }
            }

            if let mapURL = playlist.mapURL, !fm.fileExists(atPath: mapPath) {
                let data = try await fetch(session, mapURL, range: playlist.mapRange)
                try data.write(to: URL(fileURLWithPath: mapPath), options: .atomic)
            }

            let finished = locked { done }
            let pending = playlist.segments.filter { !finished.contains($0.index) }
            let workers = max(1, min(config.maxConnections, 16))
            try await withThrowingTaskGroup(of: Void.self) { group in
                var iterator = pending.makeIterator()
                for _ in 0..<workers {
                    if let seg = iterator.next() {
                        group.addTask { try await self.download(seg, session: session) }
                    }
                }
                while try await group.next() != nil {
                    if let seg = iterator.next() {
                        group.addTask { try await self.download(seg, session: session) }
                    }
                }
            }

            if isStopped { return }
            DispatchQueue.main.async { self.onEvent?(.assembling) }
            let ext = try assemble(playlist)
            try? fm.removeItem(atPath: partsDirectory)
            stopTimer()
            let snap = snapshot()
            DispatchQueue.main.async {
                self.onEvent?(.progress(snap))
                self.onEvent?(.finished(preferredExtension: ext))
            }
        } catch {
            if isStopped || error is CancellationError { return }
            stopTimer()
            let snap = snapshot()
            let message = error.localizedDescription
            DispatchQueue.main.async {
                self.onEvent?(.progress(snap))
                self.onEvent?(.failed(message))
            }
        }
    }

    private var mapPath: String { (partsDirectory as NSString).appendingPathComponent("init.mp4") }

    private func partPath(_ index: Int) -> String {
        (partsDirectory as NSString).appendingPathComponent(String(format: "%06d.part", index))
    }

    private func key(for key: HLSKey, session: URLSession) async throws -> Data {
        guard let uri = key.uri else {
            throw NSError(domain: "MacOSDownloadManager", code: 5, userInfo: [NSLocalizedDescriptionKey: String(localized: "Missing decryption key")])
        }
        if let cached = locked({ keyCache[uri] }) { return cached }
        let data = try await fetch(session, uri)
        locked { keyCache[uri] = data }
        return data
    }

    private func download(_ seg: HLSSegment, session: URLSession) async throws {
        if Task.isCancelled || isStopped { throw CancellationError() }
        locked { active += 1 }
        defer { locked { active -= 1 } }

        var data = try await fetch(session, seg.url, range: seg.byteRange)
        if let k = seg.key, k.method == "AES-128" {
            let keyData = try await key(for: k, session: session)
            let iv = k.iv ?? AES128.iv(forSequence: seg.sequence)
            guard let plain = AES128.decrypt(data, key: keyData, iv: iv) else {
                throw NSError(domain: "MacOSDownloadManager", code: 6, userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not decrypt the stream")])
            }
            data = plain
        }
        try data.write(to: URL(fileURLWithPath: partPath(seg.index)), options: .atomic)

        let size = data.count
        locked {
            done.insert(seg.index)
            bytesDone += Int64(size)
            meter.add(size)
        }

        let delay = SpeedLimiter.shared.consume(data.count)
        if delay > 0.01 {
            try await Task.sleep(nanoseconds: UInt64(min(delay, 10) * 1_000_000_000))
        }
    }

    private func assemble(_ playlist: HLSPlaylist) throws -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: tempPath) { try fm.removeItem(atPath: tempPath) }
        guard fm.createFile(atPath: tempPath, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: tempPath))
        defer { try? out.close() }
        if playlist.mapURL != nil, let mapData = fm.contents(atPath: mapPath) {
            try out.write(contentsOf: mapData)
        }
        for seg in playlist.segments {
            if isStopped { throw CancellationError() }
            guard let data = fm.contents(atPath: partPath(seg.index)) else {
                throw NSError(domain: "MacOSDownloadManager", code: 7, userInfo: [NSLocalizedDescriptionKey: String(localized: "A part of the stream is missing")])
            }
            try out.write(contentsOf: data)
        }
        try out.synchronize()
        if playlist.mapURL != nil { return "mp4" }
        let ext = playlist.segments.first?.url.pathExtension.lowercased() ?? "ts"
        if ["aac", "mp3", "m4a", "mp4", "m4s"].contains(ext) { return ext == "m4s" ? "mp4" : ext }
        return "ts"
    }

    // MARK: Progress

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.speed = self.meter.tick()
            self.lock.unlock()
            let snap = self.snapshot()
            DispatchQueue.main.async { self.onEvent?(.progress(snap)) }
        }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func snapshot() -> EngineProgress {
        lock.lock(); defer { lock.unlock() }
        var estimatedTotal: Int64 = -1
        if segmentCount > 0, !done.isEmpty {
            estimatedTotal = Int64(Double(bytesDone) / Double(done.count) * Double(segmentCount))
        }
        return EngineProgress(downloaded: bytesDone,
                              total: estimatedTotal,
                              segments: [],
                              speed: stopped ? 0 : speed,
                              connections: active,
                              activeSegments: [],
                              resumable: true,
                              hlsDone: Array(done).sorted(),
                              hlsCount: segmentCount)
    }
}
