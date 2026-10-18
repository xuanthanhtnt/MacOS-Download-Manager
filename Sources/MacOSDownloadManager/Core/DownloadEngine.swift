import Foundation

struct EngineConfig {
    var maxConnections: Int
    var minSplitSize: Int64 = 256 * 1024
    var retries: Int
    var timeout: TimeInterval
    var headers: [String: String]
    var credential: URLCredential?
    var proxy: [AnyHashable: Any]?
}

struct EngineProgress {
    var downloaded: Int64
    var total: Int64
    var segments: [Segment]
    var speed: Double
    var connections: Int
    var activeSegments: [Int]
    var resumable: Bool
    var hlsDone: [Int]? = nil
    var hlsCount: Int? = nil
}

enum EngineEvent {
    case metadata(total: Int64, resumable: Bool, suggestedName: String?, mime: String?)
    case progress(EngineProgress)
    case assembling
    case stopped(EngineProgress)
    case finished(preferredExtension: String?)
    case failed(String)
}

protocol DownloadEngine: AnyObject {
    var onEvent: ((EngineEvent) -> Void)? { get set }
    func start()
    func stop()
}

/// Multi-connection HTTP(S) downloader with IDM-style dynamic file segmentation.
///
/// The first connection asks for `bytes=0-`. As soon as the server confirms it supports ranges,
/// the remaining bytes are split between new connections. Every time a connection finishes its
/// part, the largest unfinished part is split in two and a new connection takes the second half,
/// so all connections stay busy until the very end of the file.
final class HTTPDownloadEngine: NSObject, DownloadEngine, URLSessionDataDelegate {
    var onEvent: ((EngineEvent) -> Void)?

    private final class Connection {
        let segmentID: Int
        let session: URLSession
        let task: URLSessionDataTask
        var isProbe: Bool
        var closing = false

        init(segmentID: Int, session: URLSession, task: URLSessionDataTask, isProbe: Bool) {
            self.segmentID = segmentID
            self.session = session
            self.task = task
            self.isProbe = isProbe
        }
    }

    private let url: URL
    private let tempPath: String
    private let config: EngineConfig
    private let queue: DispatchQueue
    private let delegateQueue: OperationQueue

    private var total: Int64
    private var resumable: Bool
    private var segments: [Segment]
    private var nextSegmentID: Int
    private var file: FileHandle?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var failures: [Int: Int] = [:]
    private var waitingRetry: Set<Int> = []
    private var lastError: String?
    private var restarts = 0
    private var effectiveMax: Int
    private var stopped = false
    private var finished = false
    private var meter = SpeedMeter()
    private var currentSpeed: Double = 0
    private var timer: DispatchSourceTimer?
    private let stopLock = NSLock()
    private var stopRequestedFlag = false

    /// Set from any thread as soon as stop() is called, so queued callbacks can bail out quickly.
    private var stopRequested: Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stopRequestedFlag
    }

    init(item: DownloadItem, tempPath: String, config: EngineConfig) {
        self.url = item.url
        self.tempPath = tempPath
        self.config = config
        self.total = item.totalBytes
        self.resumable = item.resumable
        self.segments = item.segments
        self.nextSegmentID = (item.segments.map(\.id).max() ?? -1) + 1
        self.queue = DispatchQueue(label: "mdm.engine.\(item.id.uuidString)")
        self.delegateQueue = OperationQueue()
        self.effectiveMax = max(1, config.maxConnections)
        super.init()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
    }

    // MARK: Public

    func start() {
        queue.async { [self] in
            do {
                try openFile()
            } catch {
                fail(String(localized: "Cannot create the file: ") + error.localizedDescription)
                return
            }
            startTimer()
            let hasProgress = segments.contains { $0.downloaded > 0 }
            if resumable && total > 0 && !segments.isEmpty && hasProgress {
                fillConnections()
            } else {
                startFresh()
            }
        }
    }

    func stop() {
        stopLock.lock()
        stopRequestedFlag = true
        stopLock.unlock()
        queue.async { [self] in
            guard !stopped, !finished else { return }
            stopped = true
            cancelAllConnections()
            stopTimer()
            closeFile()
            let snap = snapshot()
            DispatchQueue.main.async { self.onEvent?(.stopped(snap)) }
        }
    }

    // MARK: File

    private func openFile() throws {
        let fm = FileManager.default
        let dir = (tempPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: tempPath) {
            guard fm.createFile(atPath: tempPath, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        file = try FileHandle(forUpdating: URL(fileURLWithPath: tempPath))
    }

    private func closeFile() {
        if let file {
            try? file.synchronize()
            try? file.close()
        }
        file = nil
    }

    // MARK: Connections

    private func startFresh() {
        cancelAllConnections()
        try? file?.truncate(atOffset: 0)
        total = -1
        let seg = Segment(id: nextSegmentID, start: 0, end: -1, downloaded: 0)
        nextSegmentID += 1
        segments = [seg]
        launch(seg.id, probe: true)
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 1
        cfg.timeoutIntervalForRequest = config.timeout
        cfg.timeoutIntervalForResource = 60 * 60 * 24 * 7
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        if config.headers.keys.contains(where: { $0.lowercased() == "cookie" }) {
            cfg.httpShouldSetCookies = false
        }
        if let proxy = config.proxy {
            cfg.connectionProxyDictionary = proxy
        }
        // One session per connection: every range request gets its own TCP connection.
        return URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
    }

    private func launch(_ segmentID: Int, probe: Bool = false) {
        guard !stopped, !finished, let idx = index(of: segmentID) else { return }
        let seg = segments[idx]
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: config.timeout)
        for (key, value) in config.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if probe {
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        } else if seg.end >= 0 {
            request.setValue("bytes=\(seg.current)-\(seg.end)", forHTTPHeaderField: "Range")
        } else if seg.current > 0 {
            request.setValue("bytes=\(seg.current)-", forHTTPHeaderField: "Range")
        }
        let session = makeSession()
        let task = session.dataTask(with: request)
        let connection = Connection(segmentID: segmentID, session: session, task: task, isProbe: probe)
        connections[ObjectIdentifier(task)] = connection
        task.resume()
    }

    private func close(_ c: Connection) {
        c.closing = true
        connections.removeValue(forKey: ObjectIdentifier(c.task))
        c.task.cancel()
        c.session.invalidateAndCancel()
    }

    private func cancelAllConnections() {
        for c in connections.values {
            c.closing = true
            c.task.cancel()
            c.session.invalidateAndCancel()
        }
        connections.removeAll()
    }

    private func index(of segmentID: Int) -> Int? {
        segments.firstIndex { $0.id == segmentID }
    }

    private func isActive(_ segmentID: Int) -> Bool {
        connections.values.contains { $0.segmentID == segmentID }
    }

    /// Starts connections for idle parts and splits the biggest running part while connections are free.
    private func fillConnections() {
        guard !stopped, !finished else { return }
        guard resumable, total > 0 else {
            checkCompletion()
            return
        }
        let maxConnections = max(1, effectiveMax)

        for seg in segments where !seg.isComplete && !isActive(seg.id) && !waitingRetry.contains(seg.id) {
            if connections.count >= maxConnections { break }
            if (failures[seg.id] ?? 0) > config.retries { continue }
            launch(seg.id)
        }

        var splits = 0
        while connections.count < maxConnections && splits < 64 {
            splits += 1
            var best: (idx: Int, remaining: Int64)?
            for (i, seg) in segments.enumerated() where isActive(seg.id) && !seg.isComplete && seg.end >= 0 {
                if best == nil || seg.remaining > best!.remaining { best = (i, seg.remaining) }
            }
            guard let target = best, target.remaining >= config.minSplitSize * 2 else { break }
            let seg = segments[target.idx]
            let splitPoint = seg.current + target.remaining / 2
            let newSeg = Segment(id: nextSegmentID, start: splitPoint, end: seg.end, downloaded: 0)
            nextSegmentID += 1
            segments[target.idx].end = splitPoint - 1
            segments.append(newSeg)
            launch(newSeg.id)
        }
        checkCompletion()
    }

    private func checkCompletion() {
        guard !stopped, !finished else { return }
        if !segments.isEmpty, segments.allSatisfy({ $0.isComplete }) {
            finishDownload()
            return
        }
        if connections.isEmpty && waitingRetry.isEmpty {
            fail(lastError ?? String(localized: "Download failed"))
        }
    }

    private func finishDownload() {
        guard !finished else { return }
        finished = true
        cancelAllConnections()
        if total > 0 {
            try? file?.truncate(atOffset: UInt64(total))
        }
        closeFile()
        stopTimer()
        let snap = snapshot()
        DispatchQueue.main.async {
            self.onEvent?(.progress(snap))
            self.onEvent?(.finished(preferredExtension: nil))
        }
    }

    private func fail(_ message: String) {
        guard !finished, !stopped else { return }
        finished = true
        cancelAllConnections()
        closeFile()
        stopTimer()
        let snap = snapshot()
        DispatchQueue.main.async {
            self.onEvent?(.progress(snap))
            self.onEvent?(.failed(message))
        }
    }

    private func restartFromScratch(_ reason: String) {
        restarts += 1
        if restarts > 3 {
            fail(reason)
            return
        }
        resumable = true
        startFresh()
    }

    private func connectionFailed(_ c: Connection, message: String, fatal: Bool, serverBusy: Bool = false) {
        if !c.closing { close(c) }
        lastError = message
        if fatal {
            fail(message)
            return
        }
        let n = (failures[c.segmentID] ?? 0) + 1
        failures[c.segmentID] = n

        // The probe connection, or a server without range support: the whole transfer has to restart.
        if c.isProbe || !resumable || total <= 0 {
            if n > config.retries {
                fail(message)
                return
            }
            let delay = min(Double(n) * 2, 15)
            let failedID = c.segmentID
            waitingRetry.insert(failedID)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.stopped, !self.finished else { return }
                self.waitingRetry.remove(failedID)
                self.startFresh()
                if let first = self.segments.first { self.failures[first.id] = n }
            }
            return
        }

        if serverBusy && !connections.isEmpty {
            // The server limits the number of connections: use fewer of them. This is not a real
            // failure of the part (other connections are making progress), so it is not counted.
            effectiveMax = max(1, min(effectiveMax, connections.count))
            failures[c.segmentID] = n - 1
        } else if n > config.retries {
            // Give up on this part for now; the others continue.
            fillConnections()
            return
        }
        let delay = min(Double(n) * 2, 15)
        let failedID = c.segmentID
        waitingRetry.insert(failedID)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, !self.finished else { return }
            self.waitingRetry.remove(failedID)
            self.fillConnections()
        }
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !stopped, !finished, let c = connections[ObjectIdentifier(dataTask)], !c.closing,
              let idx = index(of: c.segmentID) else {
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200

        if status >= 400 {
            completionHandler(.cancel)
            let fatal = [401, 404, 410].contains(status) || (status == 403 && c.isProbe)
            connectionFailed(c, message: HTTPUtils.message(forStatus: status), fatal: fatal,
                             serverBusy: status == 429 || status == 503 || status == 403)
            return
        }

        let contentRange = HTTPUtils.parseContentRange(http?.value(forHTTPHeaderField: "Content-Range"))

        if c.isProbe {
            var newTotal: Int64 = -1
            var canResume = false
            if status == 206, let cr = contentRange, cr.start == 0 {
                newTotal = cr.total
                canResume = cr.total > 0
            } else {
                newTotal = response.expectedContentLength > 0 ? response.expectedContentLength : -1
                canResume = false
            }
            total = newTotal
            resumable = canResume
            c.isProbe = false
            if total > 0 {
                segments[idx].end = total - 1
                try? file?.truncate(atOffset: UInt64(total))
            }
            var suggested: String?
            if let cd = http?.value(forHTTPHeaderField: "Content-Disposition") {
                suggested = FileNameUtils.parseContentDisposition(cd)
            }
            if suggested == nil, let finalURL = response.url, finalURL != url, !finalURL.pathExtension.isEmpty {
                suggested = FileNameUtils.nameFromURL(finalURL)
            }
            let mime = response.mimeType
            let t = total, r = resumable
            DispatchQueue.main.async {
                self.onEvent?(.metadata(total: t, resumable: r, suggestedName: suggested, mime: mime))
            }
            completionHandler(.allow)
            if resumable { fillConnections() }
            return
        }

        let seg = segments[idx]
        if status == 206 {
            if let cr = contentRange {
                if cr.total > 0, total > 0, cr.total != total {
                    completionHandler(.cancel)
                    close(c)
                    restartFromScratch(String(localized: "The file on the server has changed"))
                    return
                }
                if cr.start != seg.current {
                    completionHandler(.cancel)
                    connectionFailed(c, message: String(localized: "The server returned an unexpected range"), fatal: false)
                    return
                }
            }
            completionHandler(.allow)
        } else if status == 200 {
            if seg.current == 0 {
                completionHandler(.allow)
            } else {
                // The server ignored our Range header: resuming is not possible anymore.
                completionHandler(.cancel)
                close(c)
                restartFromScratch(String(localized: "The server does not support resuming"))
            }
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped, !finished, !stopRequested, let c = connections[ObjectIdentifier(dataTask)], !c.closing,
              let idx = index(of: c.segmentID) else { return }
        var chunk = data
        let seg = segments[idx]
        if seg.end >= 0 {
            let remaining = seg.end - seg.current + 1
            if remaining <= 0 {
                close(c)
                fillConnections()
                return
            }
            if Int64(chunk.count) > remaining {
                chunk = chunk.prefix(Int(remaining))
            }
        }
        do {
            try file?.seek(toOffset: UInt64(seg.current))
            try file?.write(contentsOf: chunk)
        } catch {
            fail(String(localized: "Disk write error: ") + error.localizedDescription)
            return
        }
        segments[idx].downloaded += Int64(chunk.count)
        meter.add(chunk.count)
        failures[c.segmentID] = 0

        // Speed limiter: every received byte is counted. Holding this download's delegate queue stops
        // URLSession from delivering more data (and, with the task suspended, from reading the socket).
        let delay = SpeedLimiter.shared.consume(chunk.count)

        if segments[idx].isComplete {
            close(c)
            throttle(delay)
            fillConnections()
            return
        }

        if delay > 0.002 {
            dataTask.suspend()
            throttle(delay)
            if !stopped && !finished && !stopRequested { dataTask.resume() }
        }
    }

    /// Sleeps on the engine queue in short steps so a stop request is honoured quickly.
    private func throttle(_ delay: TimeInterval) {
        guard delay > 0.002 else { return }
        var remaining = min(delay, 10)
        while remaining > 0 && !stopRequested {
            let step = min(remaining, 0.05)
            Thread.sleep(forTimeInterval: step)
            remaining -= step
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard let c = connections[ObjectIdentifier(task)] else { return }
        if stopped || finished || c.closing {
            connections.removeValue(forKey: ObjectIdentifier(task))
            return
        }
        guard let idx = index(of: c.segmentID) else {
            connections.removeValue(forKey: ObjectIdentifier(task))
            return
        }
        if let error {
            connectionFailed(c, message: error.localizedDescription, fatal: false)
            return
        }
        connections.removeValue(forKey: ObjectIdentifier(task))
        c.closing = true

        if segments[idx].end < 0 {
            // Unknown size: the stream ended, so the file is complete.
            let downloaded = segments[idx].downloaded
            total = downloaded
            segments[idx].end = segments[idx].start + downloaded - 1
            finishDownload()
            return
        }
        if segments[idx].isComplete {
            fillConnections()
        } else {
            connectionFailed(c, message: String(localized: "The connection was closed before the part was complete"), fatal: false)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var newRequest = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range"),
           newRequest.value(forHTTPHeaderField: "Range") == nil {
            newRequest.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(newRequest)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        let isHTTPAuth = method == NSURLAuthenticationMethodHTTPBasic
            || method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodNTLM
            || method == NSURLAuthenticationMethodDefault
        if isHTTPAuth, let credential = config.credential, challenge.previousFailureCount < 2 {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: Progress reporting

    private func startTimer() {
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self, !self.stopped, !self.finished else { return }
            self.currentSpeed = self.meter.tick()
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
        let downloaded = segments.reduce(Int64(0)) { $0 + $1.downloaded }
        let active = Array(Set(connections.values.map(\.segmentID))).sorted()
        return EngineProgress(downloaded: downloaded,
                              total: total,
                              segments: segments,
                              speed: (stopped || finished) ? 0 : currentSpeed,
                              connections: connections.count,
                              activeSegments: active,
                              resumable: resumable)
    }
}
