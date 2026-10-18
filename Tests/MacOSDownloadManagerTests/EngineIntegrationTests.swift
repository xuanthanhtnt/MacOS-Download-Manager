import XCTest
import CryptoKit
@testable import MacOSDownloadManager

/// End-to-end tests of the download engines against scripts/test_server.py.
/// They run when MDM_TEST_SERVER and MDM_TEST_FIXTURES are set (the CI workflow sets them).
final class EngineIntegrationTests: XCTestCase {
    private var server = ""
    private var fixtures = ""
    private var workDir = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["MDM_TEST_SERVER"], let f = env["MDM_TEST_FIXTURES"] else {
            throw XCTSkip("Integration test server not configured")
        }
        server = s
        fixtures = f
        workDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("mdm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        SpeedLimiter.shared.setLimit(bytesPerSecond: 0)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: workDir)
        SpeedLimiter.shared.setLimit(bytesPerSecond: 0)
    }

    // MARK: Helpers

    private func config(connections: Int = 8) -> EngineConfig {
        EngineConfig(maxConnections: connections, minSplitSize: 64 * 1024, retries: 3, timeout: 20,
                     headers: ["User-Agent": "MDM-Tests"], credential: nil, proxy: nil)
    }

    private func sha256(_ path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Outcome {
        var finished = false
        var failure: String?
        var stopped: EngineProgress?
        var last: EngineProgress?
        var maxConnections = 0
        var metadataTotal: Int64?
        var resumable: Bool?
        var preferredExtension: String?
    }

    /// Runs an engine until it finishes, fails or stops. `onProgress` may stop it.
    private func run(_ engine: DownloadEngine, timeout: TimeInterval = 90,
                     onProgress: ((EngineProgress) -> Void)? = nil) -> Outcome {
        var outcome = Outcome()
        let done = expectation(description: "engine finished")
        engine.onEvent = { event in
            switch event {
            case let .metadata(total, resumable, _, _):
                outcome.metadataTotal = total
                outcome.resumable = resumable
            case .progress(let p):
                outcome.last = p
                outcome.maxConnections = max(outcome.maxConnections, p.connections)
                onProgress?(p)
            case .assembling:
                break
            case .stopped(let p):
                outcome.stopped = p
                done.fulfill()
            case .finished(let ext):
                outcome.finished = true
                outcome.preferredExtension = ext
                done.fulfill()
            case .failed(let message):
                outcome.failure = message
                done.fulfill()
            }
        }
        engine.start()
        wait(for: [done], timeout: timeout)
        return outcome
    }

    private func item(_ path: String) -> DownloadItem {
        DownloadItem(url: URL(string: server + path)!, fileName: "out.bin", directory: workDir)
    }

    // MARK: Tests

    func testMultiConnectionDownloadMatchesSource() throws {
        let temp = (workDir as NSString).appendingPathComponent("multi.part")
        let engine = HTTPDownloadEngine(item: item("/files/big.bin"), tempPath: temp, config: config())
        let outcome = run(engine)
        XCTAssertNil(outcome.failure)
        XCTAssertTrue(outcome.finished)
        XCTAssertEqual(outcome.metadataTotal, 6_000_000)
        XCTAssertEqual(outcome.resumable, true)
        XCTAssertGreaterThan(outcome.last?.segments.count ?? 0, 1, "the file should be split between connections")
        XCTAssertEqual(try sha256(temp), try sha256(fixtures + "/files/big.bin"))
    }

    func testPauseAndResume() throws {
        let temp = (workDir as NSString).appendingPathComponent("resume.part")
        var first: HTTPDownloadEngine?
        first = HTTPDownloadEngine(item: item("/slow/big.bin"), tempPath: temp, config: config())
        let paused = run(first!) { p in
            if p.downloaded > 800_000 { first?.stop() }
        }
        XCTAssertNil(paused.failure)
        let snapshot = try XCTUnwrap(paused.stopped)
        XCTAssertLessThan(snapshot.downloaded, 6_000_000)
        XCTAssertGreaterThan(snapshot.downloaded, 0)

        var resumed = item("/files/big.bin")
        resumed.totalBytes = snapshot.total
        resumed.resumable = snapshot.resumable
        resumed.segments = snapshot.segments
        resumed.downloadedBytes = snapshot.downloaded
        let second = HTTPDownloadEngine(item: resumed, tempPath: temp, config: config())
        let outcome = run(second)
        XCTAssertNil(outcome.failure)
        XCTAssertTrue(outcome.finished)
        XCTAssertNil(outcome.metadataTotal, "a resumed download must not start over")
        XCTAssertEqual(try sha256(temp), try sha256(fixtures + "/files/big.bin"))
    }

    func testServerWithoutRangeSupport() throws {
        let temp = (workDir as NSString).appendingPathComponent("norange.part")
        let engine = HTTPDownloadEngine(item: item("/norange/big.bin"), tempPath: temp, config: config())
        let outcome = run(engine)
        XCTAssertNil(outcome.failure)
        XCTAssertTrue(outcome.finished)
        XCTAssertEqual(outcome.resumable, false)
        XCTAssertLessThanOrEqual(outcome.maxConnections, 1)
        XCTAssertEqual(try sha256(temp), try sha256(fixtures + "/files/big.bin"))
    }

    func testServerLimitingConnections() throws {
        let temp = (workDir as NSString).appendingPathComponent("busy.part")
        let engine = HTTPDownloadEngine(item: item("/busy/big.bin"), tempPath: temp, config: config())
        let outcome = run(engine, timeout: 120)
        XCTAssertNil(outcome.failure)
        XCTAssertTrue(outcome.finished)
        XCTAssertEqual(try sha256(temp), try sha256(fixtures + "/files/big.bin"))
    }

    func testMissingFileFails() {
        let temp = (workDir as NSString).appendingPathComponent("missing.part")
        let engine = HTTPDownloadEngine(item: item("/files/does-not-exist.bin"), tempPath: temp, config: config())
        let outcome = run(engine)
        XCTAssertFalse(outcome.finished)
        XCTAssertNotNil(outcome.failure)
    }

    func testSpeedLimiter() throws {
        SpeedLimiter.shared.setLimit(bytesPerSecond: 2_000_000)
        let temp = (workDir as NSString).appendingPathComponent("limited.part")
        let engine = HTTPDownloadEngine(item: item("/files/big.bin"), tempPath: temp, config: config())
        let start = Date()
        let outcome = run(engine)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(outcome.finished)
        XCTAssertGreaterThan(elapsed, 1.5, "6 MB at 2 MB/s (with a 2 MB burst) should take about 2 seconds")
        XCTAssertEqual(try sha256(temp), try sha256(fixtures + "/files/big.bin"))
    }

    func testEncryptedHLSFromMasterPlaylist() throws {
        let temp = (workDir as NSString).appendingPathComponent("video.ts")
        var hls = item("/hls/master.m3u8")
        hls.kind = .hls
        let engine = HLSDownloadEngine(item: hls, tempPath: temp, config: config(connections: 4))
        let outcome = run(engine)
        XCTAssertNil(outcome.failure)
        XCTAssertTrue(outcome.finished)
        XCTAssertEqual(outcome.preferredExtension, "ts")
        XCTAssertEqual(outcome.last?.hlsDone?.count, 5)
        XCTAssertEqual(try sha256(temp), try sha256(fixtures + "/hls/plain-all.ts"))
    }

    func testProbe() async throws {
        let result = try await URLProbe.probe(url: URL(string: server + "/files/big.bin")!, headers: [:],
                                              username: nil, password: nil, proxy: nil)
        XCTAssertEqual(result.totalBytes, 6_000_000)
        XCTAssertTrue(result.resumable)
        XCTAssertEqual(result.fileName, "big.bin")

        let hls = try await URLProbe.probe(url: URL(string: server + "/hls/master.m3u8")!, headers: [:],
                                           username: nil, password: nil, proxy: nil)
        XCTAssertTrue(hls.isHLS)
        XCTAssertEqual(hls.hlsVariants.count, 1)
    }
}
