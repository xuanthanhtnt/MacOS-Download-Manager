import Foundation
import AVFoundation
import Combine
import Darwin

// MARK: - yt-dlp JSON model

/// One format from `yt-dlp --dump-single-json`. Every field is optional and decoded leniently
/// because extractors differ a lot between sites.
struct YTDLFormat: Decodable, Hashable {
    var formatID: String
    var ext: String?
    var url: String?
    var proto: String?
    var vcodec: String?
    var acodec: String?
    var width: Int?
    var height: Int?
    var fps: Double?
    var tbr: Double?
    var abr: Double?
    var filesize: Double?
    var filesizeApprox: Double?
    var formatNote: String?
    var httpHeaders: [String: String]?
    var dynamicRange: String?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id", ext, url, proto = "protocol", vcodec, acodec, width, height, fps, tbr, abr
        case filesize, filesizeApprox = "filesize_approx", formatNote = "format_note"
        case httpHeaders = "http_headers", dynamicRange = "dynamic_range"
    }

    init(formatID: String, ext: String? = nil, url: String? = nil, proto: String? = nil,
         vcodec: String? = nil, acodec: String? = nil, height: Int? = nil, fps: Double? = nil,
         tbr: Double? = nil, abr: Double? = nil, filesize: Double? = nil) {
        self.formatID = formatID
        self.ext = ext
        self.url = url
        self.proto = proto
        self.vcodec = vcodec
        self.acodec = acodec
        self.height = height
        self.fps = fps
        self.tbr = tbr
        self.abr = abr
        self.filesize = filesize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s }
            if let n = try? c.decodeIfPresent(Double.self, forKey: k) { return String(format: "%g", n) }
            return nil
        }
        func num(_ k: CodingKeys) -> Double? {
            if let n = try? c.decodeIfPresent(Double.self, forKey: k) { return n }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Double(s) }
            return nil
        }
        formatID = str(.formatID) ?? "0"
        ext = str(.ext)
        url = str(.url)
        proto = str(.proto)
        vcodec = str(.vcodec)
        acodec = str(.acodec)
        width = num(.width).map { Int($0) }
        height = num(.height).map { Int($0) }
        fps = num(.fps)
        tbr = num(.tbr)
        abr = num(.abr)
        filesize = num(.filesize)
        filesizeApprox = num(.filesizeApprox)
        formatNote = str(.formatNote)
        httpHeaders = (try? c.decodeIfPresent([String: String].self, forKey: .httpHeaders)) ?? nil
        dynamicRange = str(.dynamicRange)
    }

    var size: Int64? {
        if let filesize, filesize > 0 { return Int64(filesize) }
        if let filesizeApprox, filesizeApprox > 0 { return Int64(filesizeApprox) }
        return nil
    }

    var bitrate: Double { tbr ?? abr ?? 0 }

    private func known(_ codec: String?) -> Bool? {
        guard let codec, !codec.isEmpty else { return nil }
        return codec != "none"
    }

    var isVideoOnly: Bool { known(vcodec) == true && known(acodec) == false }
    var isAudioOnly: Bool { known(vcodec) == false && known(acodec) == true }
    /// Contains both picture and sound (or the codecs are unknown, as for plain .mp4 links).
    var isMuxed: Bool { !isVideoOnly && !isAudioOnly && known(vcodec) != false }

    /// Plain HTTP(S) file that the multi-connection engine can download directly.
    var isDirectHTTP: Bool {
        guard url != nil else { return false }
        guard let proto else { return true }
        return proto == "https" || proto == "http"
    }

    var isHLS: Bool { (proto ?? "").hasPrefix("m3u8") }

    var codecName: String {
        let v = (vcodec ?? "").lowercased()
        if v.hasPrefix("avc1") || v.hasPrefix("h264") { return "H.264" }
        if v.hasPrefix("hvc1") || v.hasPrefix("hev1") || v.hasPrefix("h265") { return "HEVC" }
        if v.hasPrefix("vp09") || v.hasPrefix("vp9") { return "VP9" }
        if v.hasPrefix("av01") { return "AV1" }
        let a = (acodec ?? "").lowercased()
        if a.hasPrefix("mp4a") { return "AAC" }
        if a.hasPrefix("opus") { return "Opus" }
        return (ext ?? "").uppercased()
    }
}

struct YTDLInfo: Decodable {
    var id: String?
    var title: String?
    var uploader: String?
    var duration: Double?
    var thumbnail: String?
    var webpageURL: String?
    var extractor: String?
    var isLive: Bool?
    var formats: [YTDLFormat]

    enum CodingKeys: String, CodingKey {
        case id, title, uploader, duration, thumbnail, formats
        case webpageURL = "webpage_url", extractor = "extractor_key", isLive = "is_live"
    }

    init(title: String?, formats: [YTDLFormat]) {
        self.title = title
        self.formats = formats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        uploader = try? c.decodeIfPresent(String.self, forKey: .uploader)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        thumbnail = try? c.decodeIfPresent(String.self, forKey: .thumbnail)
        webpageURL = try? c.decodeIfPresent(String.self, forKey: .webpageURL)
        extractor = try? c.decodeIfPresent(String.self, forKey: .extractor)
        isLive = try? c.decodeIfPresent(Bool.self, forKey: .isLive)
        if let list = try? c.decodeIfPresent([YTDLFormat].self, forKey: .formats), !list.isEmpty {
            formats = list
        } else if let single = try? YTDLFormat(from: decoder), single.url != nil {
            // Sites with a single file put the format fields at the top level.
            formats = [single]
        } else {
            formats = []
        }
    }
}

// MARK: - Choosing what to download

enum MergeMethod: String, Codable {
    case none
    case avfoundation
    case ffmpeg
}

struct MediaOption: Identifiable, Hashable {
    var id: String { spec }
    /// yt-dlp format selector: "137+140" (video+audio), "18" (single file).
    var spec: String
    var formatIDs: [String]
    var title: String
    var detail: String
    var size: Int64?
    var ext: String
    var height: Int?
    var audioOnly: Bool
    var merge: MergeMethod
    /// All streams are plain HTTP files that the multi-connection engine downloads itself.
    var direct: Bool
}

enum MediaPlanner {
    private static func avFoundationVideo(_ f: YTDLFormat) -> Bool {
        let v = (f.vcodec ?? "").lowercased()
        let ext = (f.ext ?? "").lowercased()
        return (ext == "mp4" || ext == "mov" || ext == "m4v") && (v.hasPrefix("avc1") || v.hasPrefix("hvc1") || v.hasPrefix("hev1"))
    }

    private static func m4aAudio(_ f: YTDLFormat) -> Bool {
        let a = (f.acodec ?? "").lowercased()
        return f.ext == "m4a" || a.hasPrefix("mp4a")
    }

    /// Builds the list of qualities the user can choose from, best first, audio-only last.
    static func options(for info: YTDLInfo, ffmpeg: Bool) -> [MediaOption] {
        let formats = info.formats
        let audio = formats.filter(\.isAudioOnly)
        let bestM4A = audio.filter(m4aAudio).max { $0.bitrate < $1.bitrate }
        let bestAudio = audio.max { $0.bitrate < $1.bitrate }
        let bestWebmAudio = audio.filter { $0.ext == "webm" }.max { $0.bitrate < $1.bitrate }

        var byHeight: [Int: MediaOption] = [:]
        let videos = formats.filter { $0.isVideoOnly && $0.height != nil }.sorted { $0.bitrate > $1.bitrate }

        func add(_ v: YTDLFormat, _ audioFormat: YTDLFormat, _ merge: MergeMethod) {
            guard let h = v.height, byHeight[h] == nil else { return }
            let ext: String
            if merge == .avfoundation || (v.ext == "mp4" && m4aAudio(audioFormat)) {
                ext = "mp4"
            } else if v.ext == "webm" && audioFormat.ext == "webm" {
                ext = "webm"
            } else {
                ext = "mkv"
            }
            let size = (v.size ?? 0) + (audioFormat.size ?? 0)
            byHeight[h] = MediaOption(spec: "\(v.formatID)+\(audioFormat.formatID)",
                                      formatIDs: [v.formatID, audioFormat.formatID],
                                      title: qualityTitle(v),
                                      detail: detail(ext: ext, codec: v.codecName, size: size > 0 ? size : nil),
                                      size: size > 0 ? size : nil,
                                      ext: ext,
                                      height: h,
                                      audioOnly: false,
                                      merge: merge,
                                      direct: v.isDirectHTTP && audioFormat.isDirectHTTP)
        }

        // 1. MP4 (H.264/HEVC) + AAC: joined by macOS itself, plays everywhere.
        if let m4a = bestM4A {
            for v in videos where avFoundationVideo(v) { add(v, m4a, .avfoundation) }
        }
        // 2. Other codecs (VP9, AV1) for the remaining qualities, joined with ffmpeg when it is installed.
        if ffmpeg {
            for v in videos where !avFoundationVideo(v) {
                if let a = v.ext == "webm" ? (bestWebmAudio ?? bestAudio) : (bestM4A ?? bestAudio) {
                    add(v, a, .ffmpeg)
                }
            }
        }

        // Files that already contain picture and sound.
        for p in formats.filter(\.isMuxed).sorted(by: { $0.bitrate > $1.bitrate }) {
            let h = p.height ?? 0
            if byHeight[h] != nil { continue }
            let ext = (p.ext ?? "mp4").lowercased()
            byHeight[h] = MediaOption(spec: p.formatID, formatIDs: [p.formatID],
                                      title: h > 0 ? qualityTitle(p) : String(localized: "Video"),
                                      detail: detail(ext: ext, codec: p.codecName, size: p.size),
                                      size: p.size, ext: ext == "m3u8" ? "mp4" : ext, height: h, audioOnly: false,
                                      merge: .none, direct: p.isDirectHTTP)
        }

        var result = byHeight.values.sorted { ($0.height ?? 0) > ($1.height ?? 0) }

        if let a = bestM4A ?? bestAudio {
            let ext = m4aAudio(a) ? "m4a" : (a.ext ?? "webm")
            let kbps = a.abr ?? a.tbr
            var title = String(localized: "Audio only")
            if let kbps { title += " · \(Int(kbps)) kbps" }
            result.append(MediaOption(spec: a.formatID, formatIDs: [a.formatID], title: title,
                                      detail: detail(ext: ext, codec: a.codecName, size: a.size),
                                      size: a.size, ext: ext, height: nil, audioOnly: true,
                                      merge: .none, direct: a.isDirectHTTP))
        }
        return result
    }

    /// The option to preselect: the best quality not above `maxHeight` (0 = no limit).
    static func preferred(_ options: [MediaOption], maxHeight: Int) -> MediaOption? {
        let videos = options.filter { !$0.audioOnly }
        if maxHeight > 0, let fit = videos.first(where: { ($0.height ?? 0) <= maxHeight && ($0.height ?? 0) > 0 }) {
            return fit
        }
        return videos.first ?? options.first
    }

    /// Finds the saved choice again after the formats were re-read (links expire), or the closest one.
    static func pick(spec: String?, from options: [MediaOption], maxHeight: Int) -> MediaOption? {
        if let spec, let exact = options.first(where: { $0.spec == spec }) { return exact }
        if let spec {
            let wanted = Set(spec.split(separator: "+").map(String.init))
            if let overlap = options.first(where: { !wanted.isDisjoint(with: $0.formatIDs) }) { return overlap }
        }
        return preferred(options, maxHeight: maxHeight)
    }

    private static func qualityTitle(_ f: YTDLFormat) -> String {
        var t = "\(f.height ?? 0)p"
        if let fps = f.fps, fps > 30 { t += "\(Int(fps.rounded()))" }
        if let dr = f.dynamicRange, dr.uppercased().hasPrefix("HDR") { t += " HDR" }
        return t
    }

    private static func detail(ext: String, codec: String, size: Int64?) -> String {
        var parts = [ext.uppercased()]
        if !codec.isEmpty && codec != ext.uppercased() { parts.append(codec) }
        if let size { parts.append("~" + Fmt.bytes(size)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Joining video and audio

enum MediaMuxer {
    /// Copies the video track of `video` and the audio track of `audio` into one MP4 without re-encoding.
    static func mergeWithAVFoundation(video: URL, audio: URL, output: URL) async throws {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let sourceVideo = videoTracks.first, let sourceAudio = audioTracks.first else {
            throw MediaError.message(String(localized: "The video or audio stream could not be read"))
        }
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let transform = try await sourceVideo.load(.preferredTransform)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaError.message(String(localized: "Could not join video and audio"))
        }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = transform
        let audioLength = CMTimeMinimum(audioDuration, videoDuration.seconds > 0 ? videoDuration : audioDuration)
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: audioLength), of: sourceAudio, at: .zero)

        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaError.message(String(localized: "Could not join video and audio"))
        }
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            throw MediaError.message(export.error?.localizedDescription ?? String(localized: "Could not join video and audio"))
        }
    }

    static func mergeWithFFmpeg(_ ffmpeg: String, video: URL, audio: URL, output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        let result = try await MediaTools.runProcess(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y",
                                                              "-i", video.path, "-i", audio.path,
                                                              "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", output.path])
        guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw MediaError.message(result.stderrTail.isEmpty ? String(localized: "Could not join video and audio") : result.stderrTail)
        }
    }
}

enum MediaError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

// MARK: - Helper tools (yt-dlp, Deno, ffmpeg)

/// Manages the open-source helpers used for video sites: yt-dlp (reads the video page and lists
/// the streams) and Deno (the JavaScript runtime yt-dlp needs for YouTube). They are downloaded
/// from their official GitHub releases on first use and checked against the published SHA-256 sums.
final class MediaTools: ObservableObject {
    static let shared = MediaTools()

    @Published private(set) var ytdlpVersion: String?
    @Published private(set) var denoVersion: String?
    @Published private(set) var ffmpegPath: String?
    @Published private(set) var installing = false
    @Published private(set) var installStatus = ""
    @Published private(set) var lastError: String?

    private static let ytdlpURL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
    private static let ytdlpSums = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS"
    private static var denoAsset: String {
        #if arch(arm64)
        return "deno-aarch64-apple-darwin.zip"
        #else
        return "deno-x86_64-apple-darwin.zip"
        #endif
    }

    var toolsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MacOS Download Manager/Tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var ytdlpPath: String { toolsDirectory.appendingPathComponent("yt-dlp").path }
    var denoPath: String { toolsDirectory.appendingPathComponent("deno").path }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: ytdlpPath) && FileManager.default.isExecutableFile(atPath: denoPath)
    }

    private init() {}

    /// ffmpeg is optional (needed only for VP9/AV1 qualities): the copy installed with Homebrew is used if present.
    static func findFFmpeg() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refreshStatus() {
        let ytdlp = ytdlpPath, deno = denoPath, installed = isInstalled
        Task.detached {
            var y: String?
            var d: String?
            if installed {
                y = try? await MediaTools.runProcess(ytdlp, ["--version"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let denoOut = try? await MediaTools.runProcess(deno, ["--version"]).stdout
                d = denoOut?.split(separator: "\n").first.map { String($0).replacingOccurrences(of: "deno ", with: "") }
            }
            let f = MediaTools.findFFmpeg()
            await MainActor.run {
                self.ytdlpVersion = y
                self.denoVersion = d
                self.ffmpegPath = f
            }
        }
    }

    // MARK: Installing

    private func setStatus(_ text: String) async {
        await MainActor.run { self.installStatus = text }
    }

    /// Downloads (or re-downloads) yt-dlp and Deno.
    func install() async throws {
        await MainActor.run {
            self.installing = true
            self.lastError = nil
        }
        defer { Task { await MainActor.run { self.installing = false } } }
        do {
            try await installYtdlp()
            try await installDeno()
            await setStatus(String(localized: "Components are ready"))
            refreshStatus()
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
            await setStatus("")
            throw error
        }
    }

    private func fetch(_ url: String) async throws -> URL {
        guard let u = URL(string: url) else { throw MediaError.message("Bad URL") }
        let (file, response) = try await URLSession.shared.download(from: u)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw MediaError.message(HTTPUtils.message(forStatus: http.statusCode) + " – " + url)
        }
        return file
    }

    private func sha256(_ file: URL) throws -> String {
        try Checksum.compute(.sha256, path: file.path) { _ in }
    }

    /// Finds the SHA-256 for `name` in a checksum list ("<hash>  <file>" per line), or the first hash when `name` is nil.
    static func firstHash(in text: String, for name: String?) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*")) }
            guard let hash = tokens.first(where: { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else { continue }
            if let name {
                guard tokens.contains(where: { ($0 as NSString).lastPathComponent == name }) else { continue }
            }
            return hash.lowercased()
        }
        return nil
    }

    private func installYtdlp() async throws {
        await setStatus(String(localized: "Downloading yt-dlp…"))
        let file = try await fetch(Self.ytdlpURL)
        var sums: String?
        if let sumsFile = try? await fetch(Self.ytdlpSums) {
            sums = try? String(contentsOf: sumsFile, encoding: .utf8)
        }
        guard let expected = sums.flatMap({ Self.firstHash(in: $0, for: "yt-dlp_macos") }) else {
            throw MediaError.message(String(localized: "Could not verify the downloaded yt-dlp (checksum list missing)"))
        }
        guard try sha256(file) == expected else {
            throw MediaError.message(String(localized: "The downloaded yt-dlp failed the checksum check"))
        }
        try placeExecutable(file, at: ytdlpPath)
    }

    private func installDeno() async throws {
        await setStatus(String(localized: "Downloading Deno (JavaScript runtime for YouTube)…"))
        let base = "https://github.com/denoland/deno/releases/latest/download/" + Self.denoAsset
        let zip = try await fetch(base)
        if let sumsFile = try? await fetch(base + ".sha256sum"),
           let text = try? String(contentsOf: sumsFile, encoding: .utf8),
           let expected = Self.firstHash(in: text, for: nil) {
            guard try sha256(zip) == expected else {
                throw MediaError.message(String(localized: "The downloaded Deno failed the checksum check"))
            }
        }
        let unpack = toolsDirectory.appendingPathComponent("deno-unpack", isDirectory: true)
        try? FileManager.default.removeItem(at: unpack)
        try FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)
        let result = try await Self.runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path])
        let binary = unpack.appendingPathComponent("deno")
        guard result.status == 0, FileManager.default.fileExists(atPath: binary.path) else {
            throw MediaError.message(String(localized: "Could not unpack Deno"))
        }
        try placeExecutable(binary, at: denoPath)
        try? FileManager.default.removeItem(at: unpack)
    }

    private func placeExecutable(_ source: URL, at path: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try fm.moveItem(at: source, to: URL(fileURLWithPath: path))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        // Files written by this app are quarantined (LSFileQuarantineEnabled); helpers we verified ourselves are not.
        removexattr(path, "com.apple.quarantine", 0)
    }

    /// Updates yt-dlp to the latest release (sites change often, yt-dlp follows quickly).
    func updateYtdlp() async throws {
        await MainActor.run { self.installing = true }
        defer { Task { await MainActor.run { self.installing = false } } }
        await setStatus(String(localized: "Updating yt-dlp…"))
        let result = try await Self.runProcess(ytdlpPath, ["-U"])
        removexattr(ytdlpPath, "com.apple.quarantine", 0)
        await setStatus(result.status == 0 ? String(localized: "yt-dlp is up to date") : result.stderrTail)
        refreshStatus()
    }

    // MARK: Running yt-dlp

    func baseArguments(cookiesBrowser: String) -> [String] {
        var args = ["--no-playlist", "--no-warnings", "--js-runtimes", "deno:\(denoPath)"]
        if let ffmpeg = Self.findFFmpeg() { args += ["--ffmpeg-location", ffmpeg] }
        if !cookiesBrowser.isEmpty { args += ["--cookies-from-browser", cookiesBrowser] }
        return args
    }

    /// Reads a video page and returns its title and streams.
    func extract(url: URL, cookiesBrowser: String) async throws -> YTDLInfo {
        guard isInstalled else {
            throw MediaError.message(String(localized: "The video components are not installed yet"))
        }
        let args = baseArguments(cookiesBrowser: cookiesBrowser) + ["--dump-single-json", "--no-progress", url.absoluteString]
        let result = try await Self.runProcess(ytdlpPath, args, timeout: 120)
        guard result.status == 0, let data = result.stdout.data(using: .utf8), !data.isEmpty else {
            throw MediaError.message(Self.friendlyError(result.stderrTail))
        }
        let info = try JSONDecoder().decode(YTDLInfo.self, from: data)
        if info.isLive == true {
            throw MediaError.message(String(localized: "Live streams cannot be downloaded"))
        }
        if info.formats.isEmpty {
            throw MediaError.message(String(localized: "No downloadable video was found on this page"))
        }
        return info
    }

    static func friendlyError(_ stderr: String) -> String {
        let text = stderr.isEmpty ? String(localized: "yt-dlp could not read this page") : stderr
        if text.contains("Sign in to confirm") || text.contains("not a bot") {
            return text + "\n" + String(localized: "Tip: choose your browser under “Use cookies from” (Options → Video) and try again.")
        }
        if text.contains("Unsupported URL") {
            return String(localized: "This page is not supported for video downloads")
        }
        return text
    }

    struct ProcessResult {
        var status: Int32
        var stdout: String
        var stderr: String

        var stderrTail: String {
            let lines = stderr.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            return lines.suffix(3).joined(separator: "\n")
        }
    }

    final class OutputBuffer {
        private let lock = NSLock()
        private var data = Data()

        func append(_ d: Data) {
            lock.lock()
            data.append(d)
            lock.unlock()
        }

        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let tools = MediaTools.shared.toolsDirectory.path
        env["PATH"] = [tools, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    /// Runs a helper program and collects its output.
    static func runProcess(_ path: String, _ arguments: [String], timeout: TimeInterval = 600) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = processEnvironment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        out.fileHandleForReading.readabilityHandler = { h in stdoutBuffer.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in stderrBuffer.append(h.availableData) }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(out.fileHandleForReading.readDataToEndOfFile())
                stderrBuffer.append(err.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: ProcessResult(status: p.terminationStatus,
                                                             stdout: stdoutBuffer.string,
                                                             stderr: stderrBuffer.string))
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
