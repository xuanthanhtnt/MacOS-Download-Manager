import Foundation

/// Downloads a video page (YouTube and the other sites yt-dlp supports).
///
/// 1. yt-dlp reads the page and lists the streams (links expire, so this runs on every start/resume).
/// 2. Video and audio streams are downloaded in parallel. Plain HTTP streams use the multi-connection
///    engine (with 10 MB requests, like yt-dlp, so video CDNs do not slow them down); other protocols
///    are downloaded by yt-dlp itself.
/// 3. The streams are joined without re-encoding: by macOS (AVFoundation) for MP4 + M4A files, by
///    ffmpeg for everything else (HLS/MPEG-TS, VP9/AV1, WebM) or when macOS cannot open a stream.
///
/// All state is used on the main thread.
final class MediaDownloadEngine: DownloadEngine {
    var onEvent: ((EngineEvent) -> Void)?

    /// Reads the page. Replaceable in tests.
    var extractor: (URL) async throws -> YTDLInfo

    private let item: DownloadItem
    private let tempPath: String
    private let config: EngineConfig
    private let maxHeight: Int
    private let cookiesBrowser: String

    private var parts: [MediaPartState]
    private var partFormats: [YTDLFormat] = []
    private var option: MediaOption?
    private var subEngines: [Int: HTTPDownloadEngine] = [:]
    private var partSpeed: [Int: Double] = [:]
    private var partConnections: [Int: Int] = [:]
    private var partActive: [Int: [Int]] = [:]
    private var ytdlpPart: Int?
    private var note: String?
    private var task: Task<Void, Never>?
    private var process: Process?
    private var processProgress: (downloaded: Int64, total: Int64, speed: Double)?
    private var stopped = false
    private var finished = false
    private var merging = false

    init(item: DownloadItem, tempPath: String, config: EngineConfig, cookiesBrowser: String, maxHeight: Int) {
        self.item = item
        self.tempPath = tempPath
        self.config = config
        self.maxHeight = maxHeight
        self.cookiesBrowser = cookiesBrowser
        self.parts = item.mediaParts
        self.extractor = { url in try await MediaTools.shared.extract(url: url, cookiesBrowser: cookiesBrowser) }
    }

    // MARK: Start / stop

    func start() {
        // Every stream was downloaded in an earlier run (the join failed or was interrupted):
        // join them again without reading the page or downloading anything.
        let fm = FileManager.default
        if !parts.isEmpty, parts.allSatisfy(\.done), parts.indices.allSatisfy({ fm.fileExists(atPath: partPath($0)) }) {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, !self.finished else { return }
                self.onEvent?(.progress(self.snapshot()))
                self.checkAllDone()
            }
            return
        }
        let url = item.url
        let extractor = self.extractor
        task = Task.detached { [weak self] in
            do {
                let info = try await extractor(url)
                if Task.isCancelled { return }
                // ffmpeg (downloaded once) joins the streams macOS cannot join and fixes HLS downloads.
                _ = await MediaTools.shared.ensureFFmpeg()
                if Task.isCancelled { return }
                await MainActor.run { self?.begin(info) }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { self?.fail(message) }
            }
        }
    }

    func stop() {
        guard !stopped, !finished else { return }
        stopped = true
        task?.cancel()
        if let process, process.isRunning { process.terminate() }
        if subEngines.isEmpty {
            onEvent?(.stopped(snapshot()))
        } else {
            for engine in subEngines.values { engine.stop() }
        }
    }

    private func fail(_ message: String) {
        guard !finished, !stopped else { return }
        finished = true
        let engines = subEngines
        subEngines.removeAll()
        for engine in engines.values { engine.stop() }
        if let process, process.isRunning { process.terminate() }
        onEvent?(.progress(snapshot()))
        onEvent?(.failed(message))
    }

    private func complete(_ ext: String) {
        guard !finished else { return }
        finished = true
        onEvent?(.progress(snapshot()))
        onEvent?(.finished(preferredExtension: ext))
    }

    // MARK: Planning

    private func begin(_ info: YTDLInfo) {
        guard !stopped, !finished else { return }
        let ffmpeg = MediaTools.findFFmpeg()
        let options = MediaPlanner.options(for: info, ffmpeg: ffmpeg != nil)
        guard let chosen = MediaPlanner.pick(spec: item.mediaFormat, from: options, maxHeight: maxHeight) else {
            fail(String(localized: "No downloadable video was found on this page"))
            return
        }
        option = chosen
        var byID: [String: YTDLFormat] = [:]
        for f in info.formats where byID[f.formatID] == nil { byID[f.formatID] = f }
        partFormats = chosen.formatIDs.compactMap { byID[$0] }
        guard partFormats.count == chosen.formatIDs.count else {
            fail(String(localized: "No downloadable video was found on this page"))
            return
        }
        if chosen.merge == .ffmpeg && ffmpeg == nil {
            fail(String(localized: "This quality needs ffmpeg, which could not be downloaded. Try again, or install it with Homebrew: brew install ffmpeg"))
            return
        }

        // Keep the progress of a previous run only if it was for the same streams.
        if parts.map(\.formatID) != chosen.formatIDs {
            removePartFiles()
            parts = partFormats.map { MediaPartState(formatID: $0.formatID, ext: Self.cleanExt($0.ext)) }
        }
        onEvent?(.metadata(total: chosen.size ?? -1, resumable: true, suggestedName: nil, mime: nil))

        let fm = FileManager.default
        if parts.allSatisfy(\.done), fm.fileExists(atPath: tempPath), !parts.indices.contains(where: { fm.fileExists(atPath: partPath($0)) }) {
            complete(chosen.ext)   // joined in an earlier run that was stopped just before finishing
            return
        }
        for i in parts.indices where !fm.fileExists(atPath: partPath(i)) && (parts[i].done || parts[i].downloadedBytes > 0) {
            parts[i] = MediaPartState(formatID: parts[i].formatID, ext: parts[i].ext)
        }
        for i in parts.indices { parts[i].direct = partFormats[i].isDirectHTTP }

        // YouTube: the stream links only work from a given moment (while an ad would play). Requests
        // made earlier are refused, so wait like yt-dlp does.
        let wait = (partFormats.compactMap(\.availableAt).max() ?? 0) - Date().timeIntervalSince1970
        if wait > 0.5, parts.contains(where: { !$0.done && $0.direct == true }) {
            let seconds = Int(wait.rounded(.up))
            note = String(format: String(localized: "Waiting %d s, as YouTube requires before the download can start…"), seconds)
            Self.log("\(item.fileName): waiting \(seconds) s (YouTube available_at)")
            onEvent?(.progress(snapshot()))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.5) { [weak self] in
                guard let self, !self.stopped, !self.finished else { return }
                self.note = nil
                self.startStreams()
            }
            return
        }
        startStreams()
    }

    /// Plain files are downloaded by the app with several connections each; the others (HLS…) by
    /// yt-dlp, one after the other, at the same time as the plain ones.
    private func startStreams() {
        for i in parts.indices where !parts[i].done && parts[i].direct == true { startPart(i) }
        onEvent?(.progress(snapshot()))
        if parts.contains(where: { !$0.done && $0.direct != true }) {
            runNextWithYtdlp()
        } else {
            checkAllDone()
        }
    }

    /// Connections for one stream: the video gets the full number, the much smaller audio a few.
    private func connections(forPart i: Int) -> Int {
        let full = max(1, config.maxConnections)
        guard parts.count > 1, i > 0 else { return full }
        return max(1, min(4, full / 2))
    }

    private static func cleanExt(_ ext: String?) -> String {
        let e = (ext ?? "bin").lowercased()
        return e.isEmpty || e == "none" ? "bin" : e
    }

    private func partPath(_ i: Int) -> String {
        "\(tempPath).part\(i).\(parts[i].ext)"
    }

    private func removePartFiles() {
        let dir = (tempPath as NSString).deletingLastPathComponent
        let prefix = (tempPath as NSString).lastPathComponent + ".part"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
        }
    }

    // MARK: Direct (multi-connection) download of each stream

    private func startPart(_ i: Int) {
        let format = partFormats[i]
        guard let link = format.url, let url = URL(string: link) else {
            fail(String(localized: "No downloadable video was found on this page"))
            return
        }
        var sub = DownloadItem(url: url, fileName: "part\(i)", directory: (tempPath as NSString).deletingLastPathComponent)
        sub.totalBytes = parts[i].totalBytes
        sub.resumable = true
        sub.segments = parts[i].segments
        sub.downloadedBytes = parts[i].downloadedBytes

        var cfg = config
        var headers = cfg.headers
        for (key, value) in format.httpHeaders ?? [:] {
            // yt-dlp's headers (User-Agent, …) belong to the stream links; they replace ours.
            for existing in headers.keys where existing.lowercased() == key.lowercased() { headers.removeValue(forKey: existing) }
            headers[key] = value
        }
        cfg.headers = headers
        cfg.maxRequestSize = 10 * 1024 * 1024
        cfg.maxConnections = connections(forPart: i)
        let name = parts.count > 1 ? (i == 0 ? "video" : "audio") : "stream"
        cfg.logLabel = "\(item.fileName) [\(name) \(format.formatID)]"
        Self.log("\(cfg.logLabel ?? ""): app download, up to \(cfg.maxConnections) connections, \(Fmt.bytes(max(0, parts[i].totalBytes))) known")

        let engine = HTTPDownloadEngine(item: sub, tempPath: partPath(i), config: cfg)
        engine.onEvent = { [weak self, weak engine] event in
            guard let self, let engine, self.subEngines[i] === engine else { return }
            self.handlePart(i, event)
        }
        subEngines[i] = engine
        engine.start()
    }

    private func handlePart(_ i: Int, _ event: EngineEvent) {
        switch event {
        case let .metadata(total, _, _, _):
            if total > 0 { parts[i].totalBytes = total }
        case .progress(let p):
            parts[i].segments = p.segments
            parts[i].downloadedBytes = p.downloaded
            if p.total > 0 { parts[i].totalBytes = p.total }
            partSpeed[i] = p.speed
            partConnections[i] = p.connections
            partActive[i] = p.activeSegments
            if !stopped && !finished { onEvent?(.progress(snapshot())) }
        case .assembling:
            break
        case .stopped(let p):
            parts[i].segments = p.segments
            parts[i].downloadedBytes = p.downloaded
            subEngines[i] = nil
            partSpeed[i] = 0
            partConnections[i] = 0
            partActive[i] = []
            if subEngines.isEmpty && stopped { onEvent?(.stopped(snapshot())) }
        case .finished:
            parts[i].done = true
            parts[i].segments = []
            if parts[i].totalBytes > 0 { parts[i].downloadedBytes = parts[i].totalBytes }
            subEngines[i] = nil
            partSpeed[i] = 0
            partConnections[i] = 0
            partActive[i] = []
            checkAllDone()
        case .failed(let message):
            subEngines[i] = nil
            fail(message)
        }
    }

    // MARK: Streams yt-dlp downloads itself (HLS/DASH fragments, …)

    private func runNextWithYtdlp() {
        guard !stopped, !finished, ytdlpPart == nil else { return }
        guard let i = parts.indices.first(where: { !parts[$0].done && parts[$0].direct != true }) else {
            checkAllDone()
            return
        }
        ytdlpPart = i
        Self.log("\(item.fileName) [part \(i) \(parts[i].formatID)]: downloaded by yt-dlp (\(partFormats.indices.contains(i) ? partFormats[i].proto ?? "?" : "?"), \(max(1, min(16, config.maxConnections))) fragments at a time)")
        let template = "\(tempPath).part\(i).%(ext)s"
        let args = MediaTools.shared.baseArguments(cookiesBrowser: cookiesBrowser) + [
            "-f", parts[i].formatID,
            "--newline", "--no-mtime", "--continue",
            "-N", "\(max(1, min(16, config.maxConnections)))",
            "--progress-template",
            "download:MDM %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s",
            "-o", template,
            item.url.absoluteString
        ]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: MediaTools.shared.ytdlpPath)
        p.arguments = args
        p.environment = MediaTools.processEnvironment
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let errors = MediaTools.OutputBuffer()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // yt-dlp prints one progress line per update (--newline); use the newest complete one.
            let text = String(decoding: data, as: UTF8.self)
            guard let lastLine = text.split(separator: "\n").last(where: { $0.hasPrefix("MDM ") && $0.split(separator: " ").count >= 5 }) else { return }
            let fields = lastLine.split(separator: " ").map(String.init)
            guard fields.count >= 5 else { return }
            let downloaded = Int64(Double(fields[1]) ?? 0)
            let total = Int64(Double(fields[2]) ?? Double(fields[3]) ?? -1)
            let speed = Double(fields[4]) ?? 0
            DispatchQueue.main.async {
                guard let self, !self.stopped, !self.finished else { return }
                self.processProgress = (downloaded, total, speed)
                self.parts[i].downloadedBytes = downloaded
                if total > 0 { self.parts[i].totalBytes = total }
                self.onEvent?(.progress(self.snapshot()))
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in errors.append(handle.availableData) }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            errors.append(err.fileHandleForReading.readDataToEndOfFile())
            let status = proc.terminationStatus
            let message = MediaTools.ProcessResult(status: status, stdout: "", stderr: errors.string).stderrTail
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.processProgress = nil
                self.ytdlpPart = nil
                if self.stopped {
                    return
                }
                guard status == 0, let file = self.downloadedFile(forPart: i) else {
                    self.fail(MediaTools.friendlyError(message))
                    return
                }
                let ext = (file as NSString).pathExtension.lowercased()
                self.parts[i].ext = Self.cleanExt(ext)
                let target = self.partPath(i)
                if file != target {
                    try? FileManager.default.removeItem(atPath: target)
                    try? FileManager.default.moveItem(atPath: file, toPath: target)
                }
                self.parts[i].done = true
                self.runNextWithYtdlp()
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func downloadedFile(forPart i: Int) -> String? {
        let dir = (tempPath as NSString).deletingLastPathComponent
        let prefix = (tempPath as NSString).lastPathComponent + ".part\(i)."
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix(prefix) && !$0.hasSuffix(".part") && !$0.hasSuffix(".ytdl") && !$0.contains(".part-Frag") }
        let paths = names.map { (dir as NSString).appendingPathComponent($0) }
        return paths.max { size($0) < size($1) }
    }

    private func size(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Joining

    private func checkAllDone() {
        guard !parts.isEmpty, parts.allSatisfy(\.done), !merging, !finished, !stopped else { return }
        merging = true
        onEvent?(.assembling)
        let paths = parts.indices.map { URL(fileURLWithPath: partPath($0)) }
        let output = URL(fileURLWithPath: tempPath)
        let ext = option?.ext ?? Self.outputExtension(item.fileName)
        let vcodec = (partFormats.first?.vcodec ?? "").lowercased()
        let hevc = vcodec.hasPrefix("hvc1") || vcodec.hasPrefix("hev1")
        Task.detached { [weak self] in
            do {
                try await Self.join(paths, into: output, ext: ext, hevc: hevc)
                await MainActor.run { self?.complete(ext) }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self?.merging = false
                    self?.fail(message)
                }
            }
        }
    }

    private static func outputExtension(_ fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["mp4", "m4a", "mkv", "webm", "mov"].contains(ext) ? ext : "mp4"
    }

    /// Joins the downloaded streams (or fixes a single one) into `output`, removing the parts afterwards.
    ///
    /// ffmpeg (downloaded by the app) joins first: it is what yt-dlp itself uses for YouTube and it
    /// accepts every container. macOS (AVFoundation) is used when ffmpeg is missing or fails.
    static func join(_ paths: [URL], into output: URL, ext: String, hevc: Bool = false) async throws {
        let fm = FileManager.default
        let containers = paths.map(MediaMuxer.sniff)
        let temp = URL(fileURLWithPath: output.path + ".join." + ext)
        defer { try? fm.removeItem(at: temp) }

        if paths.count == 1 {
            // A single file: only an MPEG-TS saved as .mp4 (HLS without ffmpeg) needs rewriting.
            if containers[0] == .mpegTS && ext != "ts" {
                guard let ffmpeg = await MediaTools.shared.ensureFFmpeg() else {
                    throw MediaError.message(String(localized: "This video was saved as MPEG-TS, which needs ffmpeg to become MP4. ffmpeg could not be downloaded: try again."))
                }
                try await MediaMuxer.remuxWithFFmpeg(ffmpeg, input: paths[0], output: temp)
                try? fm.removeItem(at: output)
                try fm.moveItem(at: temp, to: output)
                try? fm.removeItem(at: paths[0])
            } else {
                try? fm.removeItem(at: output)
                try fm.moveItem(at: paths[0], to: output)
            }
            return
        }

        // The joined file is as big as the streams together: check the disk has room for it.
        let needed = paths.reduce(Int64(0)) { $0 + fileSize($1) }
        let folder = output.deletingLastPathComponent()
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < needed + 100 * 1024 * 1024 {
            let message = String(format: String(localized: "Not enough free disk space to join video and audio: %@ needed, %@ free. Free up space, then click Resume."),
                                 Fmt.bytes(needed + 100 * 1024 * 1024), Fmt.bytes(free))
            log("\(output.lastPathComponent): \(message)")
            throw MediaError.message(message)
        }

        var problems: [String] = []
        var joined = false
        if let ffmpeg = await MediaTools.shared.ensureFFmpeg() {
            do {
                try await MediaMuxer.mergeWithFFmpeg(ffmpeg, video: paths[0], audio: paths[1], output: temp, hevc: hevc)
                joined = true
            } catch {
                problems.append("ffmpeg: " + error.localizedDescription)
            }
        } else {
            problems.append("ffmpeg: " + (MediaTools.shared.lastError ?? String(localized: "could not be downloaded")))
        }
        if !joined && containers.allSatisfy({ $0 == .mp4 }) {
            do {
                try await MediaMuxer.mergeWithAVFoundation(video: paths[0], audio: paths[1], output: temp)
                joined = true
            } catch {
                problems.append("macOS: " + error.localizedDescription)
            }
        }
        guard joined else {
            let kinds = zip(["video", "audio"], containers).map { "\($0)=\($1)" }.joined(separator: ", ")
            let sizes = paths.map { Fmt.bytes(fileSize($0)) }.joined(separator: " + ")
            log("\(output.lastPathComponent): join failed (\(kinds); \(sizes))\n  " + problems.joined(separator: "\n  "))
            // The causes first: the status line shows the beginning of the message.
            throw MediaError.message(problems.joined(separator: "\n") + "\n" + String(localized: "Could not join video and audio") + " (\(kinds); \(sizes))")
        }
        try? fm.removeItem(at: output)
        try fm.moveItem(at: temp, to: output)
        for p in paths { try? fm.removeItem(at: p) }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// Video join problems are kept in ~/Library/Logs/MacOS Download Manager/video.log (for bug reports).
    static func log(_ text: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacOS Download Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("video.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    // MARK: Progress

    private func snapshot() -> EngineProgress {
        let downloaded = parts.reduce(Int64(0)) { $0 + max(0, $1.downloadedBytes) }
        let totals = parts.map(\.totalBytes)
        var total: Int64 = option?.size ?? -1
        if !parts.isEmpty && totals.allSatisfy({ $0 > 0 }) {
            total = totals.reduce(0, +)
        }
        var speed = partSpeed.values.reduce(0, +)
        var connections = partConnections.values.reduce(0, +)
        var perPart = parts.indices.map { partConnections[$0] ?? 0 }
        if let p = processProgress {
            speed += p.speed
            let fragments = max(1, min(16, config.maxConnections))
            connections += fragments
            if let i = ytdlpPart, perPart.indices.contains(i) { perPart[i] = fragments }
        }
        return EngineProgress(downloaded: downloaded,
                              total: total,
                              segments: [],
                              speed: (stopped || finished) ? 0 : speed,
                              connections: connections,
                              activeSegments: [],
                              resumable: true,
                              mediaParts: parts,
                              mediaActive: parts.indices.map { partActive[$0] ?? [] },
                              mediaConnections: perPart,
                              note: note)
    }
}
