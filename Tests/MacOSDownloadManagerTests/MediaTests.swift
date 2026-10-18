import XCTest
import AVFoundation
@testable import MacOSDownloadManager

/// Format choice, joining video+audio and the video download engine.
final class MediaTests: XCTestCase {

    // MARK: Format planning (no network)

    private func youtubeLikeInfo() throws -> YTDLInfo {
        let json = """
        {"id":"x","title":"Test video","duration":10,"formats":[
          {"format_id":"sb0","ext":"mhtml","protocol":"mhtml","vcodec":"none","acodec":"none"},
          {"format_id":"139","ext":"m4a","protocol":"https","url":"https://a/139","vcodec":"none","acodec":"mp4a.40.5","abr":48,"filesize":100000},
          {"format_id":"140","ext":"m4a","protocol":"https","url":"https://a/140","vcodec":"none","acodec":"mp4a.40.2","abr":129.5,"filesize":200000},
          {"format_id":"251","ext":"webm","protocol":"https","url":"https://a/251","vcodec":"none","acodec":"opus","abr":160,"filesize":210000},
          {"format_id":"18","ext":"mp4","protocol":"https","url":"https://a/18","vcodec":"avc1.42001E","acodec":"mp4a.40.2","height":360,"tbr":500,"filesize":700000},
          {"format_id":"136","ext":"mp4","protocol":"https","url":"https://a/136","vcodec":"avc1.4d401f","acodec":"none","height":720,"fps":30,"tbr":1500,"filesize":1500000},
          {"format_id":"247","ext":"webm","protocol":"https","url":"https://a/247","vcodec":"vp9","acodec":"none","height":720,"fps":30,"tbr":1700,"filesize":1600000},
          {"format_id":"299","ext":"mp4","protocol":"https","url":"https://a/299","vcodec":"avc1.64002a","acodec":"none","height":1080,"fps":60,"tbr":4000,"filesize":4000000},
          {"format_id":"400","ext":"mp4","protocol":"https","url":"https://a/400","vcodec":"av01.0.12M.08","acodec":"none","height":1440,"fps":60,"tbr":9000,"filesize":9000000,"dynamic_range":"SDR"},
          {"format_id":"hls-1","ext":"mp4","protocol":"m3u8_native","url":"https://a/hls.m3u8","vcodec":"avc1.4d401f","acodec":"mp4a.40.2","height":480,"tbr":900}
        ]}
        """
        return try JSONDecoder().decode(YTDLInfo.self, from: Data(json.utf8))
    }

    func testOptionsWithoutFFmpeg() throws {
        let options = MediaPlanner.options(for: try youtubeLikeInfo(), ffmpeg: false)
        let specs = options.map(\.spec)
        XCTAssertEqual(specs.first, "299+140", "best H.264 quality joined with AAC audio")
        XCTAssertTrue(specs.contains("136+140"))
        XCTAssertFalse(specs.contains { $0.hasPrefix("400") }, "AV1 needs ffmpeg")
        XCTAssertTrue(specs.contains("18"), "file with picture and sound")
        XCTAssertTrue(specs.contains("hls-1"))
        XCTAssertEqual(options.first { $0.spec == "hls-1" }?.direct, false, "HLS is downloaded by yt-dlp")
        XCTAssertEqual(options.last?.spec, "140", "audio only (AAC) last")
        XCTAssertEqual(options.first?.merge, .avfoundation)
        XCTAssertEqual(options.first?.ext, "mp4")
        XCTAssertEqual(options.first?.title, "1080p60")
        XCTAssertEqual(options.first?.size, 4_200_000)
        XCTAssertEqual(MediaPlanner.preferred(options, maxHeight: 720)?.spec, "136+140")
        XCTAssertEqual(MediaPlanner.pick(spec: "136+999", from: options, maxHeight: 0)?.spec, "136+140")
    }

    func testOptionsWithFFmpeg() throws {
        let options = MediaPlanner.options(for: try youtubeLikeInfo(), ffmpeg: true)
        let av1 = try XCTUnwrap(options.first)
        XCTAssertEqual(av1.spec, "400+140")
        XCTAssertEqual(av1.merge, .ffmpeg)
        XCTAssertEqual(av1.ext, "mp4")
        // H.264 is still preferred where it exists (plays everywhere, joined by macOS).
        XCTAssertEqual(options.first { $0.height == 720 }?.spec, "136+140")
    }

    func testSingleFileSite() throws {
        let json = #"{"title":"Clip","url":"https://cdn.example.com/clip.mp4","ext":"mp4","format_id":"0","protocol":"https"}"#
        let info = try JSONDecoder().decode(YTDLInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.formats.count, 1)
        let options = MediaPlanner.options(for: info, ffmpeg: false)
        XCTAssertEqual(options.first?.spec, "0")
        XCTAssertEqual(options.first?.direct, true)
    }

    func testChecksumListParsing() {
        let sums = """
        aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111  yt-dlp_macos.zip
        bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222  yt-dlp_macos
        """
        XCTAssertEqual(MediaTools.firstHash(in: sums, for: "yt-dlp_macos"), "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222")
        XCTAssertEqual(MediaTools.firstHash(in: "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333", for: nil)?.prefix(4), "cccc")
    }

    func testVideoSiteDetection() {
        XCTAssertTrue(MediaSites.isVideoPage(URL(string: "https://www.youtube.com/watch?v=abc")!))
        XCTAssertTrue(MediaSites.isVideoPage(URL(string: "https://youtu.be/abc")!))
        XCTAssertTrue(MediaSites.isVideoPage(URL(string: "https://www.tiktok.com/@a/video/1")!))
        XCTAssertFalse(MediaSites.isVideoPage(URL(string: "https://www.youtube.com/")!))
        XCTAssertFalse(MediaSites.isVideoPage(URL(string: "https://example.com/file.zip")!))
    }

    // MARK: Sample media (written with AVFoundation)

    static func makeVideo(_ url: URL, seconds: Int = 2) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let fps = 10
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixels = buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                memset(base, Int32((frame * 12) % 255), CVPixelBufferGetBytesPerRow(pixels) * 240)
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func makeAudio(_ url: URL, seconds: Double = 2) throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1
        ])
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { samples[i] = sinf(Float(i) * 2 * .pi * 440 / 44_100) * 0.3 }
        try file.write(from: buffer)
    }

    private func trackCounts(_ url: URL) async throws -> (video: Int, audio: Int, duration: Double) {
        let asset = AVURLAsset(url: url)
        let v = try await asset.loadTracks(withMediaType: .video).count
        let a = try await asset.loadTracks(withMediaType: .audio).count
        let d = try await asset.load(.duration).seconds
        return (v, a, d)
    }

    func testJoinVideoAndAudio() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mdm-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("v.mp4")
        let audio = dir.appendingPathComponent("a.m4a")
        let output = dir.appendingPathComponent("out.mp4")
        try Self.makeVideo(video)
        try Self.makeAudio(audio)
        try await MediaMuxer.mergeWithAVFoundation(video: video, audio: audio, output: output)
        let result = try await trackCounts(output)
        XCTAssertEqual(result.video, 1)
        XCTAssertEqual(result.audio, 1)
        XCTAssertEqual(result.duration, 2, accuracy: 0.3)
    }

    // MARK: Video download engine against the local test server

    func testMediaEngineDownloadsAndJoinsStreams() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["MDM_TEST_SERVER"], let fixtures = env["MDM_TEST_FIXTURES"] else {
            throw XCTSkip("Integration test server not configured")
        }
        // Serve a video-only MP4 and an AAC audio file, like YouTube's separate streams.
        let files = URL(fileURLWithPath: fixtures).appendingPathComponent("files")
        try Self.makeVideo(files.appendingPathComponent("stream-video.mp4"), seconds: 3)
        try Self.makeAudio(files.appendingPathComponent("stream-audio.m4a"), seconds: 3)

        let info = YTDLInfo(title: "Local test", formats: [
            YTDLFormat(formatID: "137", ext: "mp4", url: server + "/files/stream-video.mp4", proto: "https",
                       vcodec: "avc1.4d401e", acodec: "none", height: 240, tbr: 500),
            YTDLFormat(formatID: "140", ext: "m4a", url: server + "/files/stream-audio.m4a", proto: "https",
                       vcodec: "none", acodec: "mp4a.40.2", abr: 128)
        ])

        let workDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("mdm-media-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workDir) }
        var item = DownloadItem(url: URL(string: "https://www.youtube.com/watch?v=test")!, fileName: "Local test.mp4", directory: workDir)
        item.kind = .media
        item.mediaFormat = "137+140"
        let temp = (workDir as NSString).appendingPathComponent("Local test.mp4.mdmpart")
        let config = EngineConfig(maxConnections: 4, minSplitSize: 16 * 1024, retries: 2, timeout: 20,
                                  headers: [:], credential: nil, proxy: nil)
        let engine = MediaDownloadEngine(item: item, tempPath: temp, config: config, cookiesBrowser: "", maxHeight: 0)
        engine.extractor = { _ in info }

        var finishedExt: String?
        var failure: String?
        var sawAssembling = false
        var lastParts: [MediaPartState] = []
        let done = expectation(description: "media download finished")
        engine.onEvent = { event in
            switch event {
            case .progress(let p): if let parts = p.mediaParts { lastParts = parts }
            case .assembling: sawAssembling = true
            case .finished(let ext): finishedExt = ext; done.fulfill()
            case .failed(let message): failure = message; done.fulfill()
            case .stopped: done.fulfill()
            case .metadata: break
            }
        }
        engine.start()
        wait(for: [done], timeout: 90)
        XCTAssertNil(failure)
        XCTAssertEqual(finishedExt, "mp4")
        XCTAssertTrue(sawAssembling)
        XCTAssertEqual(lastParts.count, 2)
        XCTAssertTrue(lastParts.allSatisfy(\.done))

        // The app renames the finished file to its real name (.mp4); do the same before opening it.
        let movie = URL(fileURLWithPath: (workDir as NSString).appendingPathComponent("check.mp4"))
        try FileManager.default.moveItem(at: URL(fileURLWithPath: temp), to: movie)
        let counts = try waitForTrackCounts(movie)
        XCTAssertEqual(counts.video, 1)
        XCTAssertEqual(counts.audio, 1)
        XCTAssertEqual(counts.duration, 3, accuracy: 0.4)
    }

    private final class CountsBox {
        var counts: (video: Int, audio: Int, duration: Double)?
        var error: Error?
    }

    private func waitForTrackCounts(_ url: URL) throws -> (video: Int, audio: Int, duration: Double) {
        let box = CountsBox()
        let loaded = expectation(description: "tracks loaded")
        Task {
            do { box.counts = try await self.trackCounts(url) } catch { box.error = error }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 30)
        if let error = box.error { throw error }
        return try XCTUnwrap(box.counts)
    }

    func testChunkedRequestsDownloadCorrectly() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["MDM_TEST_SERVER"], let fixtures = env["MDM_TEST_FIXTURES"] else {
            throw XCTSkip("Integration test server not configured")
        }
        let workDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("mdm-chunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workDir) }
        let temp = (workDir as NSString).appendingPathComponent("big.part")
        let item = DownloadItem(url: URL(string: server + "/files/big.bin")!, fileName: "big.bin", directory: workDir)
        var config = EngineConfig(maxConnections: 4, minSplitSize: 64 * 1024, retries: 2, timeout: 20,
                                  headers: [:], credential: nil, proxy: nil)
        config.maxRequestSize = 300 * 1024
        let engine = HTTPDownloadEngine(item: item, tempPath: temp, config: config)
        var ok = false
        let done = expectation(description: "done")
        engine.onEvent = { event in
            switch event {
            case .finished: ok = true; done.fulfill()
            case .failed, .stopped: done.fulfill()
            default: break
            }
        }
        engine.start()
        wait(for: [done], timeout: 60)
        XCTAssertTrue(ok)
        let downloaded = try Data(contentsOf: URL(fileURLWithPath: temp))
        let original = try Data(contentsOf: URL(fileURLWithPath: fixtures + "/files/big.bin"))
        XCTAssertEqual(downloaded, original)
    }

    // MARK: Real tools and YouTube (CI only; YouTube may refuse data-center addresses)

    func testInstallToolsAndDownloadFromYouTube() async throws {
        guard ProcessInfo.processInfo.environment["MDM_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Network tests are disabled")
        }
        let tools = MediaTools.shared
        try await tools.install()
        XCTAssertTrue(tools.isInstalled, "yt-dlp and Deno must be installed")
        let version = try await MediaTools.runProcess(tools.ytdlpPath, ["--version"]).stdout
        print("MDM-NOTE yt-dlp \(version.trimmingCharacters(in: .whitespacesAndNewlines))")

        let page = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!
        let info: YTDLInfo
        do {
            info = try await tools.extract(url: page, cookiesBrowser: "")
        } catch {
            throw XCTSkip("YouTube refused this runner: \(error.localizedDescription)")
        }
        let options = MediaPlanner.options(for: info, ffmpeg: false)
        print("MDM-NOTE YouTube options: \(options.map { "\($0.title)=\($0.spec)" }.joined(separator: ", "))")
        XCTAssertFalse(options.isEmpty)
        // Smallest quality that is joined by macOS: exercises the real video+audio download and join.
        guard let smallest = options.filter({ $0.merge == .avfoundation }).last else {
            XCTFail("No MP4 + AAC quality offered")
            return
        }
        let workDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("mdm-yt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workDir) }
        var item = DownloadItem(url: page, fileName: "yt.mp4", directory: workDir)
        item.kind = .media
        item.mediaFormat = smallest.spec
        let temp = (workDir as NSString).appendingPathComponent("yt.mp4.mdmpart")
        let config = EngineConfig(maxConnections: 4, retries: 3, timeout: 30, headers: [:], credential: nil, proxy: nil)
        let result: (ext: String?, error: String?) = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let engine = MediaDownloadEngine(item: item, tempPath: temp, config: config, cookiesBrowser: "", maxHeight: 0)
                var resumed = false
                engine.onEvent = { event in
                    guard !resumed else { return }
                    switch event {
                    case .finished(let ext): resumed = true; continuation.resume(returning: (ext, nil)); _ = engine
                    case .failed(let message): resumed = true; continuation.resume(returning: (nil, message)); _ = engine
                    default: break
                    }
                }
                engine.start()
            }
        }
        if let error = result.error {
            throw XCTSkip("YouTube download refused on this runner: \(error)")
        }
        XCTAssertEqual(result.ext, "mp4")
        let counts = try await trackCounts(URL(fileURLWithPath: temp))
        print("MDM-NOTE YouTube download OK: \(smallest.title), video tracks \(counts.video), audio tracks \(counts.audio), \(counts.duration)s")
        XCTAssertEqual(counts.video, 1)
        XCTAssertEqual(counts.audio, 1)
    }
}
