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
    /// Unix time from which the stream links work (YouTube makes players wait while an ad would play).
    var availableAt: Double?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id", ext, url, proto = "protocol", vcodec, acodec, width, height, fps, tbr, abr
        case filesize, filesizeApprox = "filesize_approx", formatNote = "format_note"
        case httpHeaders = "http_headers", dynamicRange = "dynamic_range", availableAt = "available_at"
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
        availableAt = num(.availableAt)
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
    /// yt-dlp leaves the codec of HLS audio renditions empty: no picture and an unknown codec is audio too.
    var isAudioOnly: Bool { known(vcodec) == false && known(acodec) != false }
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
    /// H.264/HEVC + AAC (or a plain file): plays in QuickTime and on every Mac. VP9/AV1 do not everywhere.
    var compatible: Bool = true
}

enum MediaPlanner {
    private static func avFoundationVideo(_ f: YTDLFormat) -> Bool {
        let v = (f.vcodec ?? "").lowercased()
        let ext = (f.ext ?? "").lowercased()
        return (ext == "mp4" || ext == "mov" || ext == "m4v") && (v.hasPrefix("avc1") || v.hasPrefix("hvc1") || v.hasPrefix("hev1"))
    }

    private static func m4aAudio(_ f: YTDLFormat) -> Bool {
        let a = (f.acodec ?? "").lowercased()
        if f.ext == "m4a" || a.hasPrefix("mp4a") { return true }
        // HLS audio without codec information (yt-dlp leaves it empty) is AAC in practice.
        return a.isEmpty && f.isHLS && (f.ext == "mp4" || f.ext == "m4a")
    }

    /// Builds the list of qualities the user can choose from, best first, audio-only last.
    ///
    /// Plain HTTPS streams (YouTube's normal MP4/M4A files) are preferred: the multi-connection engine
    /// downloads them and macOS joins them. HLS streams (which yt-dlp now also gets from YouTube) are
    /// downloaded by yt-dlp as MPEG-TS, which macOS cannot open: they are only offered with ffmpeg,
    /// which turns them into MP4.
    static func options(for info: YTDLInfo, ffmpeg: Bool) -> [MediaOption] {
        let formats = info.formats
        let anyDirect = formats.contains { $0.isDirectHTTP && !$0.isAudioOnly }
        func usable(_ f: YTDLFormat) -> Bool { f.isDirectHTTP || ffmpeg || !anyDirect }
        /// Direct streams first, then the higher bitrate.
        func better(_ a: YTDLFormat, _ b: YTDLFormat) -> Bool {
            if a.isDirectHTTP != b.isDirectHTTP { return a.isDirectHTTP }
            return a.bitrate > b.bitrate
        }
        let audio = formats.filter { $0.isAudioOnly && usable($0) }.sorted(by: better)
        let bestM4A = audio.first(where: m4aAudio)
        let bestAudio = audio.first
        let bestWebmAudio = audio.first { $0.ext == "webm" }

        var byHeight: [Int: MediaOption] = [:]
        let videos = formats.filter { $0.isVideoOnly && $0.height != nil && usable($0) }.sorted(by: better)

        func add(_ v: YTDLFormat, _ audioFormat: YTDLFormat, compatible: Bool) {
            guard let h = v.height, byHeight[h] == nil else { return }
            let direct = v.isDirectHTTP && audioFormat.isDirectHTTP
            // macOS joins plain MP4 + M4A files; anything else (HLS, VP9/AV1, WebM) is joined by ffmpeg.
            let merge: MergeMethod = (compatible && direct) || !ffmpeg ? .avfoundation : .ffmpeg
            let ext: String
            if compatible || (v.ext == "mp4" && m4aAudio(audioFormat)) {
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
                                      direct: direct,
                                      compatible: compatible)
        }

        // 1. MP4 (H.264/HEVC) + AAC: plays everywhere.
        if let m4a = bestM4A {
            for v in videos where avFoundationVideo(v) { add(v, m4a, compatible: true) }
        }
        // 2. Other codecs (VP9, AV1) for the remaining qualities, joined with ffmpeg.
        if ffmpeg {
            for v in videos where !avFoundationVideo(v) {
                let webm = v.ext == "webm"
                if let a = webm ? (bestWebmAudio ?? bestAudio) : (bestM4A ?? bestAudio) {
                    add(v, a, compatible: false)
                }
            }
        }

        // Files that already contain picture and sound.
        for p in formats.filter({ $0.isMuxed && usable($0) }).sorted(by: better) {
            let h = p.height ?? 0
            if byHeight[h] != nil { continue }
            let ext = (p.ext ?? "mp4").lowercased()
            let v = (p.vcodec ?? "").lowercased()
            let compatible = !(v.hasPrefix("vp") || v.hasPrefix("av01")) && ext != "webm"
            byHeight[h] = MediaOption(spec: p.formatID, formatIDs: [p.formatID],
                                      title: h > 0 ? qualityTitle(p) : String(localized: "Video"),
                                      detail: detail(ext: ext, codec: p.codecName, size: p.size),
                                      size: p.size, ext: ext == "m3u8" ? "mp4" : ext, height: h, audioOnly: false,
                                      merge: .none, direct: p.isDirectHTTP, compatible: compatible)
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
                                      merge: .none, direct: a.isDirectHTTP, compatible: m4aAudio(a)))
        }
        return result
    }

    /// The option to preselect: the best quality not above `maxHeight` (0 = no limit). Unless a quality
    /// above 1080p is asked for, qualities that play everywhere (H.264) win over VP9/AV1 ones.
    static func preferred(_ options: [MediaOption], maxHeight: Int) -> MediaOption? {
        let videos = options.filter { !$0.audioOnly }
        let compatible = videos.filter(\.compatible)
        let pool = maxHeight <= 1080 && !compatible.isEmpty ? compatible : videos
        if maxHeight > 0, let fit = pool.first(where: { ($0.height ?? 0) <= maxHeight && ($0.height ?? 0) > 0 }) {
            return fit
        }
        return pool.first ?? options.first
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
        // The tracks' own time ranges: streams (e.g. YouTube DASH files) do not always start at zero
        // or last exactly as long as the file says.
        let videoRange = try await sourceVideo.load(.timeRange)
        let audioRange = try await sourceAudio.load(.timeRange)
        let transform = try await sourceVideo.load(.preferredTransform)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaError.message(String(localized: "Could not join video and audio"))
        }
        try videoTrack.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = transform
        let audioLength = videoRange.duration.seconds > 0 ? CMTimeMinimum(audioRange.duration, videoRange.duration) : audioRange.duration
        try audioTrack.insertTimeRange(CMTimeRange(start: audioRange.start, duration: audioLength), of: sourceAudio, at: .zero)

        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaError.message(String(localized: "Could not join video and audio"))
        }
        export.outputURL = output
        export.outputFileType = .mp4
        // Moving the index to the front needs a second copy of the file: not worth it for local files.
        export.shouldOptimizeForNetworkUse = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            throw MediaError.message(export.error?.localizedDescription ?? String(localized: "Could not join video and audio"))
        }
    }

    static func mergeWithFFmpeg(_ ffmpeg: String, video: URL, audio: URL, output: URL, hevc: Bool = false) async throws {
        var args = ["-i", video.path, "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0"]
        // QuickTime only plays HEVC in MP4 with the "hvc1" tag (ffmpeg writes "hev1" by default).
        if hevc { args += ["-tag:v", "hvc1"] }
        try await runFFmpeg(ffmpeg, args, output: output)
    }

    /// Rewrites one file into the container of `output` (e.g. MPEG-TS → MP4) without re-encoding.
    static func remuxWithFFmpeg(_ ffmpeg: String, input: URL, output: URL) async throws {
        try await runFFmpeg(ffmpeg, ["-i", input.path, "-map", "0"], output: output)
    }

    private static func runFFmpeg(_ ffmpeg: String, _ inputs: [String], output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        var args = ["-hide_banner", "-loglevel", "error", "-y"] + inputs + ["-c", "copy"]
        if ["mp4", "m4a", "mov", "m4v"].contains(output.pathExtension.lowercased()) {
            args += ["-movflags", "+faststart"]
        }
        let result = try await MediaTools.runProcess(ffmpeg, args + [output.path], timeout: 3 * 60 * 60)
        guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            throw MediaError.message(result.stderrTail.isEmpty ? String(localized: "Could not join video and audio") : result.stderrTail)
        }
    }

    enum Container: Equatable {
        case mp4        // ISO base media (MP4, M4A, MOV, fragmented/DASH MP4): macOS can open it
        case mpegTS     // MPEG transport stream (HLS): macOS cannot open it as a file
        case matroska   // MKV / WebM
        case unknown
    }

    /// Looks at the first bytes of a file to find its real format (the extension can be wrong:
    /// yt-dlp saves HLS streams as MPEG-TS in a .mp4 file when ffmpeg is missing).
    static func sniff(_ url: URL) -> Container {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 189 * 2)) ?? Data()
        let bytes = [UInt8](head)
        if bytes.count >= 8 {
            let box = String(decoding: bytes[4..<8], as: UTF8.self)
            if ["ftyp", "styp", "moov", "mdat", "free", "skip", "wide", "sidx", "moof", "pdin"].contains(box) { return .mp4 }
        }
        if bytes.count >= 4, bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 { return .matroska }
        if let first = bytes.first, first == 0x47, bytes.count < 189 || bytes[188] == 0x47 { return .mpegTS }
        return .unknown
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
/// the streams), Deno (the JavaScript runtime yt-dlp needs for YouTube) and ffmpeg (joins streams
/// that macOS cannot join itself, and turns HLS/MPEG-TS downloads into MP4). yt-dlp and Deno come
/// from their official GitHub releases, ffmpeg from Martin Riedl's signed macOS builds
/// (ffmpeg.martin-riedl.de); all are checked against their published SHA-256 sums on first use.
final class MediaTools: ObservableObject {
    static let shared = MediaTools()

    @Published private(set) var ytdlpVersion: String?
    @Published private(set) var denoVersion: String?
    @Published private(set) var ffmpegPath: String?
    @Published private(set) var ffmpegVersion: String?
    @Published private(set) var installing = false
    @Published private(set) var installStatus = ""
    @Published private(set) var lastError: String?

    private static let ytdlpURL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
    private static let ytdlpSums = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS"
    private static var ffmpegArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }
    static var ffmpegDownloadURL: String {
        "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(ffmpegArch)/release/ffmpeg.zip"
    }
    private let installQueue = SerialWork()

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
    /// The app's own copy of ffmpeg (a copy installed with Homebrew is used too).
    var ffmpegToolPath: String { toolsDirectory.appendingPathComponent("ffmpeg").path }

    /// yt-dlp and Deno: enough to read video pages.
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: ytdlpPath) && FileManager.default.isExecutableFile(atPath: denoPath)
    }

    /// All components, ffmpeg included.
    var isComplete: Bool { isInstalled && Self.findFFmpeg() != nil }

    private init() {}

    static func findFFmpeg() -> String? {
        let candidates = [MediaTools.shared.ffmpegToolPath, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refreshStatus() {
        let ytdlp = ytdlpPath, deno = denoPath, installed = isInstalled
        Task.detached {
            var y: String?
            var d: String?
            var fv: String?
            if installed {
                y = try? await MediaTools.runProcess(ytdlp, ["--version"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let denoOut = try? await MediaTools.runProcess(deno, ["--version"]).stdout
                d = denoOut?.split(separator: "\n").first.map { String($0).replacingOccurrences(of: "deno ", with: "") }
            }
            let f = MediaTools.findFFmpeg()
            if let f, let out = try? await MediaTools.runProcess(f, ["-hide_banner", "-version"], timeout: 30).stdout {
                // "ffmpeg version 9.0.2 Copyright …"
                let words = out.split(separator: "\n").first?.split(separator: " ") ?? []
                fv = words.count > 2 ? String(words[2]) : nil
            }
            await MainActor.run {
                self.ytdlpVersion = y
                self.denoVersion = d
                self.ffmpegPath = f
                self.ffmpegVersion = fv
            }
        }
    }

    // MARK: Installing

    private func setStatus(_ text: String) async {
        await MainActor.run { self.installStatus = text }
    }

    /// Downloads (or re-downloads) yt-dlp, Deno and ffmpeg.
    func install() async throws {
        try await install(onlyMissing: false)
    }

    /// Downloads the components that are not there yet (for example ffmpeg, added in version 1.1.3).
    func installMissing() async throws {
        try await install(onlyMissing: true)
    }

    /// Makes sure ffmpeg is available; returns its path, or nil when it could not be downloaded.
    func ensureFFmpeg() async -> String? {
        if let path = Self.findFFmpeg() { return path }
        try? await installQueue.run { [self] in
            if Self.findFFmpeg() == nil { try await self.runInstall { try await self.installFFmpeg() } }
        }
        return Self.findFFmpeg()
    }

    private func install(onlyMissing: Bool) async throws {
        try await installQueue.run { [self] in
            try await self.runInstall {
                let fm = FileManager.default
                if !onlyMissing || !fm.isExecutableFile(atPath: self.ytdlpPath) { try await self.installYtdlp() }
                if !onlyMissing || !fm.isExecutableFile(atPath: self.denoPath) { try await self.installDeno() }
                // ffmpeg is only needed for some streams: a failure is reported but does not stop video downloads.
                if !onlyMissing || Self.findFFmpeg() == nil {
                    do {
                        try await self.installFFmpeg()
                    } catch {
                        await MainActor.run { self.lastError = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func runInstall(_ work: () async throws -> Void) async throws {
        await MainActor.run {
            self.installing = true
            self.lastError = nil
        }
        defer { Task { await MainActor.run { self.installing = false } } }
        do {
            try await work()
            await setStatus(String(localized: "Components are ready"))
            refreshStatus()
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
            await setStatus("")
            refreshStatus()
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

    private func installFFmpeg() async throws {
        await setStatus(String(localized: "Downloading ffmpeg (joins video and audio)…"))
        guard let url = URL(string: Self.ffmpegDownloadURL) else { throw MediaError.message("Bad URL") }
        let (zip, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw MediaError.message(HTTPUtils.message(forStatus: http.statusCode) + " – " + url.absoluteString)
        }
        // The "latest" address redirects to the versioned file; its checksum sits next to it.
        let fileURL = response.url ?? url
        guard let sumsFile = try? await fetch(fileURL.absoluteString + ".sha256"),
              let text = try? String(contentsOf: sumsFile, encoding: .utf8),
              let expected = Self.firstHash(in: text, for: nil) else {
            throw MediaError.message(String(localized: "Could not verify the downloaded ffmpeg (checksum missing)"))
        }
        guard try sha256(zip) == expected else {
            throw MediaError.message(String(localized: "The downloaded ffmpeg failed the checksum check"))
        }
        let unpack = toolsDirectory.appendingPathComponent("ffmpeg-unpack", isDirectory: true)
        try? FileManager.default.removeItem(at: unpack)
        try FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unpack) }
        let result = try await Self.runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path])
        let found = FileManager.default.enumerator(at: unpack, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "ffmpeg" && !$0.hasDirectoryPath }
        guard result.status == 0, let binary = found else {
            throw MediaError.message(String(localized: "Could not unpack ffmpeg"))
        }
        // These builds are signed by their author: make sure the signature is intact.
        let signature = try await Self.runProcess("/usr/bin/codesign", ["--verify", "--strict", binary.path], timeout: 60)
        guard signature.status == 0 else {
            throw MediaError.message(String(localized: "The downloaded ffmpeg is not correctly signed") + "\n" + signature.stderrTail)
        }
        try placeExecutable(binary, at: ffmpegToolPath)
    }

    private func placeExecutable(_ source: URL, at path: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try fm.moveItem(at: source, to: URL(fileURLWithPath: path))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        // Helpers we verified ourselves must not be quarantined (versions before 1.1.2 quarantined them).
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

/// Runs async jobs one after another (two windows must not install the same component at once).
final class SerialWork {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func run(_ job: @escaping () async throws -> Void) async throws {
        try await enqueue(job).value
    }

    private func enqueue(_ job: @escaping () async throws -> Void) -> Task<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        let task = Task<Void, Error> {
            await previous?.value
            try await job()
        }
        tail = Task { _ = try? await task.value }
        return task
    }
}
