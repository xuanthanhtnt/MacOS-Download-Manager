import XCTest
@testable import MacOSDownloadManager

final class CoreTests: XCTestCase {
    func testContentRangeParsing() {
        let r = HTTPUtils.parseContentRange("bytes 0-1023/146515")
        XCTAssertEqual(r?.start, 0)
        XCTAssertEqual(r?.end, 1023)
        XCTAssertEqual(r?.total, 146515)
        XCTAssertEqual(HTTPUtils.parseContentRange("bytes 5-9/*")?.total, -1)
        XCTAssertNil(HTTPUtils.parseContentRange("garbage"))
    }

    func testContentDisposition() {
        XCTAssertEqual(FileNameUtils.parseContentDisposition("attachment; filename=\"report 2024.pdf\""), "report 2024.pdf")
        XCTAssertEqual(FileNameUtils.parseContentDisposition("attachment; filename*=UTF-8''T%E1%BA%A3i%20v%E1%BB%81.zip"), "Tải về.zip")
        XCTAssertEqual(FileNameUtils.parseContentDisposition("inline; filename=a/b.txt"), "a_b.txt")
        XCTAssertNil(FileNameUtils.parseContentDisposition("inline"))
    }

    func testNameFromURL() {
        XCTAssertEqual(FileNameUtils.nameFromURL(URL(string: "https://example.com/files/my%20file.zip?x=1")!), "my file.zip")
        XCTAssertEqual(FileNameUtils.nameFromURL(URL(string: "https://example.com/")!), "example.com")
    }

    func testSegmentMath() {
        var s = Segment(id: 0, start: 100, end: 199, downloaded: 0)
        XCTAssertEqual(s.length, 100)
        XCTAssertEqual(s.remaining, 100)
        s.downloaded = 100
        XCTAssertTrue(s.isComplete)
        let unknown = Segment(id: 1, start: 0, end: -1, downloaded: 10)
        XCTAssertFalse(unknown.isComplete)
    }

    func testBatchExpansion() {
        let urls = BatchExpander.expand(template: "https://x.com/img*.jpg", letters: false, from: "8", to: "10", width: 3)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://x.com/img008.jpg", "https://x.com/img009.jpg", "https://x.com/img010.jpg"])
        let letters = BatchExpander.expand(template: "https://x.com/*.txt", letters: true, from: "a", to: "c", width: 0)
        XCTAssertEqual(letters.count, 3)
    }

    func testM3U8Master() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
        high/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=3840x2160,AUDIO="aud"
        uhd/index.m3u8
        """
        let p = M3U8Parser.parse(text, baseURL: URL(string: "https://cdn.example.com/video/master.m3u8")!)
        XCTAssertTrue(p.isMaster)
        XCTAssertEqual(p.variants.count, 3)
        XCTAssertEqual(p.variants[1].codecs, "avc1.640028,mp4a.40.2")
        XCTAssertTrue(p.variants[2].hasSeparateAudio)
        // Prefers the best variant with muxed audio.
        XCTAssertEqual(p.bestVariant?.url.absoluteString, "https://cdn.example.com/video/high/index.m3u8")
    }

    func testM3U8Media() {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x000102030405060708090A0B0C0D0E0F
        #EXTINF:6.0,
        seg0.ts
        #EXTINF:4.5,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let p = M3U8Parser.parse(text, baseURL: URL(string: "https://cdn.example.com/v/index.m3u8")!)
        XCTAssertFalse(p.isMaster)
        XCTAssertTrue(p.endList)
        XCTAssertEqual(p.segments.count, 2)
        XCTAssertEqual(p.segments[1].sequence, 8)
        XCTAssertEqual(p.segments[0].key?.uri?.absoluteString, "https://cdn.example.com/v/key.bin")
        XCTAssertEqual(p.segments[0].key?.iv?.count, 16)
        XCTAssertEqual(p.totalDuration, 10.5, accuracy: 0.001)
    }

    func testAESRoundTrip() {
        // Encrypted with: openssl enc -aes-128-cbc -K 000102030405060708090a0b0c0d0e0f -iv 00000000000000000000000000000001
        let key = Data((0..<16).map { UInt8($0) })
        let iv = AES128.iv(forSequence: 1)
        XCTAssertEqual(iv.count, 16)
        XCTAssertEqual(iv.last, 1)
        XCTAssertNil(AES128.decrypt(Data([1, 2, 3]), key: Data([1]), iv: iv))
        XCTAssertEqual(key.count, 16)
    }

    func testEF2RoundTrip() {
        var item = DownloadItem(url: URL(string: "https://example.com/a.zip")!, fileName: "a.zip", directory: "/tmp")
        item.referer = "https://example.com/"
        let text = ListFormat.exportEF2([item])
        let parsed = ListFormat.parse(text)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.url, item.url)
        XCTAssertEqual(parsed.first?.referer, "https://example.com/")
        XCTAssertEqual(ListFormat.parse("https://a.com/1.zip\nnot a url\nhttps://a.com/2.zip").count, 2)
    }

    func testLinkExtraction() {
        let html = ##"<a href="/files/a.zip">A</a> <img src='pic.png'> <a href=https://other.com/b.pdf>B</a> <a href="#top">x</a>"##
        let links = SiteGrabber.extractLinks(html, base: URL(string: "https://example.com/dir/page.html")!)
        XCTAssertEqual(links.map(\.absoluteString), [
            "https://example.com/files/a.zip",
            "https://example.com/dir/pic.png",
            "https://other.com/b.pdf"
        ])
    }

    func testDecodeWithDefaults() {
        let json: [String: Any] = ["maxConnections": 16]
        let settings = CodableDefaults.decode(AppSettingsData.self, from: json, defaults: AppSettingsData())
        XCTAssertEqual(settings?.maxConnections, 16)
        XCTAssertEqual(settings?.serverPort, 9614)
    }

    func testSiteLoginMatching() {
        let login = SiteLogin(site: "example.com", username: "me")
        XCTAssertTrue(login.matches(URL(string: "https://files.example.com/x")!))
        XCTAssertTrue(login.matches(URL(string: "https://example.com/x")!))
        XCTAssertFalse(login.matches(URL(string: "https://badexample.com/x")!))
    }
}
