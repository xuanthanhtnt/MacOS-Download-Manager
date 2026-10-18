import Foundation
import AppKit
import CoreServices
import Combine

/// Owns the download list, the queues and the running engines. All methods must be called on the main thread.
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var queues: [DownloadQueue] = []
    @Published private(set) var stats: [UUID: RuntimeStats] = [:]
    @Published private(set) var runningQueues: Set<UUID> = []

    let settings = SettingsStore.shared

    private var engines: [UUID: DownloadEngine] = [:]
    private var stopping: Set<UUID> = []
    private var resumeAfterStop: Set<UUID> = []
    private var startedByQueue: Set<UUID> = []
    private var queueExcluded: [UUID: Set<UUID>] = [:]
    private var queueAttempts: [UUID: Int] = [:]
    private var saveWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var activity: NSObjectProtocol?
    private var scheduleTimer: Timer?
    private var lastScheduleFire: [String: String] = [:]
    private var appliedSettings: AppSettingsData?
    private var bootstrapped = false
    private var recentCaptures: [String: Date] = [:]

    private init() {}

    // MARK: - Storage

    private var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MacOS Download Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var itemsURL: URL { supportDirectory.appendingPathComponent("downloads.json") }
    private var queuesURL: URL { supportDirectory.appendingPathComponent("queues.json") }

    private func load() {
        if let data = try? Data(contentsOf: itemsURL),
           let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            let template = DownloadItem(url: URL(string: "about:blank")!, fileName: "", directory: "")
            items = array.compactMap { CodableDefaults.decode(DownloadItem.self, from: $0, defaults: template) }
        }
        for i in items.indices where items[i].status.isActive {
            items[i].status = .paused
        }
        if let data = try? Data(contentsOf: queuesURL),
           let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            let template = DownloadQueue(name: "")
            queues = array.compactMap { CodableDefaults.decode(DownloadQueue.self, from: $0, defaults: template) }
        }
        if !queues.contains(where: { $0.isMain }) {
            queues.insert(DownloadQueue(name: "Main Download Queue",
                                        maxConcurrent: settings.data.maxSimultaneousDownloads,
                                        isMain: true), at: 0)
        }
        let queueIDs = Set(queues.map(\.id))
        for i in items.indices {
            if let q = items[i].queueID, !queueIDs.contains(q) { items[i].queueID = nil }
        }
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(items) {
            try? data.write(to: itemsURL, options: .atomic)
        }
        if let data = try? encoder.encode(queues) {
            try? data.write(to: queuesURL, options: .atomic)
        }
    }

    private func scheduleSave() {
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.saveWork = nil
            self?.saveNow()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - Startup / shutdown

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        load()

        BrowserBridgeServer.shared.onMessage = { [weak self] message in
            guard let self else { return }
            switch message {
            case .download(let request):
                self.handleCapture(request)
            case .links(let urls, let referer):
                let requests = urls.map { CaptureRequest(url: $0, referer: referer) }
                WindowManager.shared.showLinks(requests)
            case .media(let url, let title):
                self.handleMediaPage(url, title: title)
            }
        }
        ClipboardMonitor.shared.shouldCapture = { [weak self] url in
            self?.settings.shouldCapture(url: url) ?? false
        }
        ClipboardMonitor.shared.onURL = { [weak self] url in
            self?.handleCapture(CaptureRequest(url: url), forceDialog: true)
        }

        applySettings(settings.data)
        settings.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in self?.applySettings(data) }
            .store(in: &cancellables)

        SystemActions.requestNotificationPermission()
        BrowserExtensionInstaller.refreshInstalledCopyIfNeeded()

        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkSchedules()
        }
        for q in queues where q.schedule.startOnLaunch {
            startQueue(q.id)
        }
    }

    private func applySettings(_ new: AppSettingsData) {
        let old = appliedSettings
        appliedSettings = new

        SpeedLimiter.shared.setLimit(bytesPerSecond: new.speedLimitEnabled ? Int64(max(1, new.speedLimitKBps)) * 1024 : 0)

        if old?.browserIntegration != new.browserIntegration || old?.serverPort != new.serverPort {
            if new.browserIntegration {
                BrowserBridgeServer.shared.start(port: new.serverPort)
            } else {
                BrowserBridgeServer.shared.stop()
            }
        }
        if old?.monitorClipboard != new.monitorClipboard {
            if new.monitorClipboard { ClipboardMonitor.shared.start() } else { ClipboardMonitor.shared.stop() }
        }
        if old?.showDropTarget != new.showDropTarget {
            WindowManager.shared.setDropTargetVisible(new.showDropTarget)
        }
        if old?.preventSleep != new.preventSleep {
            updateActivity()
        }
    }

    func prepareForTermination() {
        for (id, engine) in engines {
            engine.stop()
            if let i = index(of: id) { items[i].status = .paused }
        }
        engines.removeAll()
        saveNow()
    }

    // MARK: - Lookup

    func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    func item(_ id: UUID) -> DownloadItem? {
        items.first { $0.id == id }
    }

    func isRunning(_ id: UUID) -> Bool {
        engines[id] != nil && !stopping.contains(id)
    }

    var activeCount: Int { engines.count }

    var totalSpeed: Double { stats.values.reduce(0) { $0 + $1.speed } }

    var mainQueue: DownloadQueue {
        queues.first { $0.isMain } ?? queues[0]
    }

    func existingItem(for url: URL) -> DownloadItem? {
        items.first { $0.url == url && $0.status != .completed }
    }

    func queue(_ id: UUID?) -> DownloadQueue? {
        guard let id else { return nil }
        return queues.first { $0.id == id }
    }

    // MARK: - Adding downloads

    /// Entry point for downloads captured from the browser, the clipboard or drag & drop.
    func handleCapture(_ request: CaptureRequest, forceDialog: Bool = false) {
        // The same link reported twice in a row (e.g. by two browser events) opens only one dialog.
        let key = request.url.absoluteString
        if let last = recentCaptures[key], Date().timeIntervalSince(last) < 5 { return }
        recentCaptures[key] = Date()
        recentCaptures = recentCaptures.filter { Date().timeIntervalSince($0.value) < 60 }
        // Web pages with a video (YouTube, …) open the video download window.
        if MediaSites.isVideoPage(request.url) {
            WindowManager.shared.showMediaInfo(request.url)
            return
        }
        if settings.data.showFileInfoDialog || forceDialog {
            WindowManager.shared.showFileInfo(request)
        } else {
            quickAdd(request, start: true, queueID: nil)
        }
    }

    /// A web page with a video (YouTube, …): shows the video download window.
    func handleMediaPage(_ url: URL, title: String? = nil) {
        let key = "media:" + url.absoluteString
        if let last = recentCaptures[key], Date().timeIntervalSince(last) < 5 { return }
        recentCaptures[key] = Date()
        WindowManager.shared.showMediaInfo(url)
    }

    /// Adds a download without showing a dialog, deriving name, category and folder automatically.
    @discardableResult
    func quickAdd(_ request: CaptureRequest, start: Bool, queueID: UUID?) -> UUID {
        var name = request.suggestedName ?? FileNameUtils.nameFromURL(request.url)
        name = FileNameUtils.ensureExtension(name, mime: request.mime)
        let isHLS = FileNameUtils.isHLS(url: request.url, mime: request.mime)
        if isHLS {
            name = (name as NSString).deletingPathExtension + ".ts"
        }
        let category = settings.categoryName(forFileName: name)
        var item = DownloadItem(url: request.url, fileName: name, directory: settings.folder(forCategory: category))
        item.category = category
        item.kind = isHLS ? .hls : .http
        item.referer = request.referer
        item.cookies = request.cookies
        item.userAgent = request.userAgent
        item.username = request.username
        item.totalBytes = request.fileSize ?? -1
        item.autoName = request.suggestedName == nil
        item.queueID = queueID
        return add(item, password: request.password, start: start)
    }

    @discardableResult
    func add(_ newItem: DownloadItem, password: String?, start: Bool) -> UUID {
        var item = newItem
        item.fileName = FileNameUtils.sanitize(item.fileName)
        if item.fileName.isEmpty { item.fileName = "download" }
        if let q = item.queueID { item.queueOrder = nextQueueOrder(q) }
        items.append(item)
        if let password, !password.isEmpty {
            Keychain.set(password, account: "dl-\(item.id.uuidString)")
        }
        saveNow()
        if start {
            self.start(item.id)
        } else if let q = item.queueID, runningQueues.contains(q) {
            processQueues()
        }
        return item.id
    }

    private func nextQueueOrder(_ queueID: UUID) -> Int {
        (items.filter { $0.queueID == queueID }.map(\.queueOrder).max() ?? 0) + 1
    }

    // MARK: - Start / pause

    func start(_ id: UUID, fromQueue: Bool = false) {
        guard let i = index(of: id) else { return }
        if engines[id] != nil {
            if stopping.contains(id) { resumeAfterStop.insert(id) }
            return
        }
        var item = items[i]
        guard item.status != .completed else { return }
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: item.directory, withIntermediateDirectories: true)
        } catch {
            items[i].status = .failed
            items[i].errorMessage = String(localized: "Cannot create the folder: ") + error.localizedDescription
            return
        }

        if let temp = item.tempPath {
            // Video pages keep their streams in separate files; the media engine checks them itself.
            let exists = item.kind == .media
                || (item.kind == .hls ? fm.fileExists(atPath: temp + ".parts") : fm.fileExists(atPath: temp))
            if !exists { resetProgress(&item) }
            if item.kind == .http && !item.resumable && item.downloadedBytes > 0 { resetProgress(&item) }
        } else {
            resetProgress(&item)
            let reserved = Set(items.filter { $0.id != id && $0.status != .completed }.map(\.filePath))
            let target: String
            if settings.data.duplicateAction == .rename {
                target = FileNameUtils.uniquePath(directory: item.directory, fileName: item.fileName, reserved: reserved)
            } else {
                target = item.filePath
            }
            item.fileName = (target as NSString).lastPathComponent
            var temp = target + ".mdmpart"
            if fm.fileExists(atPath: temp) || fm.fileExists(atPath: temp + ".parts") {
                temp = (item.directory as NSString)
                    .appendingPathComponent("\(item.fileName).\(item.id.uuidString.prefix(8)).mdmpart")
            }
            item.tempPath = temp
        }

        item.status = .connecting
        item.errorMessage = nil
        item.lastTry = Date()
        items[i] = item

        let config = makeConfig(for: item)
        let tempPath = item.tempPath ?? (item.filePath + ".mdmpart")
        let engine: DownloadEngine
        if item.kind == .hls {
            engine = HLSDownloadEngine(item: item, tempPath: tempPath, config: config)
        } else if item.kind == .media {
            engine = MediaDownloadEngine(item: item, tempPath: tempPath, config: config,
                                         cookiesBrowser: settings.data.mediaCookiesBrowser,
                                         maxHeight: settings.data.mediaMaxHeight)
        } else {
            engine = HTTPDownloadEngine(item: item, tempPath: tempPath, config: config)
        }
        engines[id] = engine
        engine.onEvent = { [weak self, weak engine] event in
            guard let self, let engine else { return }
            self.handle(event, id: id, engine: engine)
        }
        engine.start()

        if fromQueue {
            startedByQueue.insert(id)
            queueAttempts[id, default: 0] += 1
        } else {
            startedByQueue.remove(id)
            if settings.data.showProgressDialog {
                WindowManager.shared.showProgress(id)
            }
        }
        updateActivity()
        scheduleSave()
    }

    private func resetProgress(_ item: inout DownloadItem) {
        item.segments = []
        item.downloadedBytes = 0
        item.hlsDoneSegments = []
        item.hlsSegmentCount = 0
        item.mediaParts = []
        if item.kind == .http, item.resumable == false { item.resumable = true }
    }

    private func makeConfig(for item: DownloadItem) -> EngineConfig {
        let s = settings.data
        var headers: [String: String] = [:]
        if let ua = item.userAgent, !ua.isEmpty { headers["User-Agent"] = ua } else { headers["User-Agent"] = s.userAgent }
        if let referer = item.referer, !referer.isEmpty { headers["Referer"] = referer }
        if let cookies = item.cookies, !cookies.isEmpty { headers["Cookie"] = cookies }
        var credential: URLCredential?
        if let user = item.username, !user.isEmpty {
            credential = URLCredential(user: user,
                                       password: Keychain.get(account: "dl-\(item.id.uuidString)") ?? "",
                                       persistence: .forSession)
        } else if let login = settings.siteLogin(for: item.url) {
            credential = URLCredential(user: login.username,
                                       password: Keychain.get(account: "site-\(login.id.uuidString)") ?? "",
                                       persistence: .forSession)
        }
        return EngineConfig(maxConnections: max(1, min(32, s.maxConnections)),
                            retries: max(0, s.retryCount),
                            timeout: TimeInterval(max(5, s.timeoutSeconds)),
                            headers: headers,
                            credential: credential,
                            proxy: settings.proxyDictionary)
    }

    func pause(_ id: UUID) {
        guard let i = index(of: id) else { return }
        resumeAfterStop.remove(id)
        if let q = items[i].queueID, runningQueues.contains(q) {
            queueExcluded[q, default: []].insert(id)
        }
        guard let engine = engines[id], !stopping.contains(id) else { return }
        stopping.insert(id)
        items[i].status = .paused
        stats[id] = nil
        engine.stop()
        // Safety net in case the engine never confirms.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.stopping.contains(id), let e = self.engines[id], e === engine else { return }
            self.engines[id] = nil
            self.stopping.remove(id)
            self.updateActivity()
            if self.resumeAfterStop.remove(id) != nil { self.start(id) }
        }
    }

    func pauseAll() {
        runningQueues.removeAll()
        for id in Array(engines.keys) { pause(id) }
    }

    func resumeAll() {
        for item in items where item.status == .paused || item.status == .failed || item.status == .queued {
            start(item.id)
        }
    }

    // MARK: - Engine events

    private func handle(_ event: EngineEvent, id: UUID, engine: DownloadEngine) {
        guard let current = engines[id], current === engine else { return }
        guard let i = index(of: id) else {
            engines[id] = nil
            return
        }
        switch event {
        case let .metadata(total, resumable, suggestedName, mime):
            items[i].totalBytes = total
            items[i].resumable = resumable
            items[i].status = .downloading
            if items[i].autoName, let name = suggestedName, !name.isEmpty {
                let newName = FileNameUtils.ensureExtension(FileNameUtils.sanitize(name), mime: mime)
                if !newName.isEmpty && newName != items[i].fileName {
                    let oldCategory = items[i].category
                    let wasDefaultFolder = items[i].directory == settings.folder(forCategory: oldCategory)
                    items[i].fileName = newName
                    let newCategory = settings.categoryName(forFileName: newName)
                    if wasDefaultFolder && newCategory != oldCategory {
                        items[i].category = newCategory
                        items[i].directory = settings.folder(forCategory: newCategory)
                    }
                }
            } else {
                items[i].fileName = FileNameUtils.ensureExtension(items[i].fileName, mime: mime)
            }
            items[i].autoName = false
            if !resumable {
                stats[id]?.connections = 1
            }

        case .progress(let p):
            apply(p, to: i)
            if items[i].status == .connecting && (p.downloaded > 0 || p.connections > 0) {
                items[i].status = .downloading
            }
            stats[id] = RuntimeStats(speed: p.speed, connections: p.connections, activeSegments: p.activeSegments)
            scheduleSave()

        case .assembling:
            items[i].status = .assembling

        case .stopped(let p):
            apply(p, to: i)
            engines[id] = nil
            stats[id] = nil
            stopping.remove(id)
            items[i].status = .paused
            saveNow()
            updateActivity()
            if resumeAfterStop.remove(id) != nil {
                start(id)
            } else {
                processQueues()
            }

        case .finished(let preferredExtension):
            engines[id] = nil
            stats[id] = nil
            stopping.remove(id)
            finalize(id, preferredExtension: preferredExtension)

        case .failed(let message):
            engines[id] = nil
            stats[id] = nil
            stopping.remove(id)
            items[i].status = .failed
            items[i].errorMessage = message
            saveNow()
            updateActivity()
            if !startedByQueue.contains(id) && settings.data.notifyOnComplete {
                SystemActions.notify(title: String(localized: "Download failed"), body: "\(items[i].fileName)\n\(message)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.processQueues() }
        }
    }

    private func apply(_ p: EngineProgress, to i: Int) {
        items[i].downloadedBytes = p.downloaded
        if p.total > 0 || items[i].kind == .hls { items[i].totalBytes = p.total }
        if items[i].kind == .http { items[i].segments = p.segments }
        items[i].resumable = p.resumable
        if let done = p.hlsDone { items[i].hlsDoneSegments = done }
        if let count = p.hlsCount { items[i].hlsSegmentCount = count }
        if let parts = p.mediaParts { items[i].mediaParts = parts }
    }

    private func finalize(_ id: UUID, preferredExtension: String?) {
        guard let i = index(of: id), let temp = items[i].tempPath else { return }
        var item = items[i]
        let fm = FileManager.default
        var name = item.fileName
        if let ext = preferredExtension, !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext {
            name = (name as NSString).deletingPathExtension + "." + ext
        }
        try? fm.createDirectory(atPath: item.directory, withIntermediateDirectories: true)
        var destination = (item.directory as NSString).appendingPathComponent(name)
        if fm.fileExists(atPath: destination) {
            if settings.data.duplicateAction == .overwrite {
                try? fm.removeItem(atPath: destination)
            } else {
                destination = FileNameUtils.uniquePath(directory: item.directory, fileName: name)
            }
        }
        do {
            try fm.moveItem(atPath: temp, toPath: destination)
        } catch {
            items[i].status = .failed
            items[i].errorMessage = String(localized: "Could not move the downloaded file: ") + error.localizedDescription
            saveNow()
            updateActivity()
            processQueues()
            return
        }
        try? fm.removeItem(atPath: temp + ".parts")
        let size = (try? fm.attributesOfItem(atPath: destination)[.size] as? NSNumber)?.int64Value ?? item.downloadedBytes
        DownloadManager.markAsDownloaded(destination, from: item.url, referer: item.referer)
        item.fileName = (destination as NSString).lastPathComponent
        item.tempPath = nil
        item.segments = []
        item.hlsDoneSegments = []
        item.status = .completed
        item.dateCompleted = Date()
        item.totalBytes = size
        item.downloadedBytes = size
        item.errorMessage = nil
        items[i] = item
        saveNow()
        updateActivity()
        postProcess(item)
        processQueues()
    }

    private func postProcess(_ item: DownloadItem) {
        let s = settings.data
        let fromQueue = startedByQueue.remove(item.id) != nil
        if s.notifyOnComplete {
            SystemActions.notify(title: String(localized: "Download complete"), body: item.fileName)
        }
        if s.playSoundOnComplete { SystemActions.playCompletionSound() }
        if s.openFolderOnComplete { SystemActions.revealInFinder(item.filePath) }
        if s.runCommandAfterDownload { SystemActions.runCommand(s.commandAfterDownload, filePath: item.filePath) }
        if !fromQueue && s.showCompleteDialog {
            WindowManager.shared.showProgress(item.id)
        }
    }

    // MARK: - Editing

    func delete(_ ids: Set<UUID>, deleteFiles: Bool) {
        var tempPaths: [String] = []
        for id in ids {
            if let engine = engines[id] {
                engines[id] = nil
                engine.stop()
            }
            stopping.remove(id)
            resumeAfterStop.remove(id)
            startedByQueue.remove(id)
            stats[id] = nil
            guard let i = index(of: id) else { continue }
            let item = items[i]
            if let temp = item.tempPath { tempPaths.append(temp) }
            if deleteFiles && item.status == .completed {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: item.filePath), resultingItemURL: nil)
            }
            Keychain.delete(account: "dl-\(id.uuidString)")
            items.remove(at: i)
            WindowManager.shared.close("progress-\(id.uuidString)")
        }
        if !tempPaths.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for temp in tempPaths { DownloadManager.removeTemporaryFiles(temp) }
            }
        }
        saveNow()
        updateActivity()
        processQueues()
    }

    /// Marks a finished file as downloaded from the Internet (like Safari/Chrome do), so macOS checks
    /// downloaded apps and shows "downloaded from …" before opening them. Only the finished file is marked:
    /// helper tools started by the app (yt-dlp) must be able to load their own libraries.
    static func markAsDownloaded(_ path: String, from url: URL, referer: String?) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "MacOS Download Manager",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineDataURLKey as String: url
        ]
        if let referer, let origin = URL(string: referer) {
            properties[kLSQuarantineOriginURLKey as String] = origin
        }
        var fileURL = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.quarantineProperties = properties
        try? fileURL.setResourceValues(values)
    }

    /// Removes an unfinished download's data: the temp file, HLS parts and video/audio stream files.
    static func removeTemporaryFiles(_ temp: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: temp)
        try? fm.removeItem(atPath: temp + ".parts")
        let dir = (temp as NSString).deletingLastPathComponent
        let prefix = (temp as NSString).lastPathComponent + "."
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix(prefix) {
            try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
        }
    }

    func deleteCompleted() {
        let ids = Set(items.filter { $0.status == .completed }.map(\.id))
        delete(ids, deleteFiles: false)
    }

    func redownload(_ id: UUID) {
        guard let i = index(of: id), engines[id] == nil else { return }
        if let temp = items[i].tempPath { DownloadManager.removeTemporaryFiles(temp) }
        items[i].tempPath = nil
        items[i].segments = []
        items[i].downloadedBytes = 0
        items[i].totalBytes = -1
        items[i].hlsDoneSegments = []
        items[i].hlsSegmentCount = 0
        items[i].mediaParts = []
        items[i].status = .queued
        items[i].dateCompleted = nil
        items[i].errorMessage = nil
        start(id)
    }

    /// Replaces an expired link with a fresh one while keeping the already downloaded data.
    func refreshAddress(_ id: UUID, to url: URL) {
        guard let i = index(of: id) else { return }
        items[i].url = url
        items[i].hlsVariantURL = nil
        items[i].errorMessage = nil
        saveNow()
        if engines[id] != nil {
            pause(id)
            resumeAfterStop.insert(id)
        }
    }

    func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let i = index(of: id) else { return }
        var item = items[i]
        change(&item)
        items[i] = item
        saveNow()
    }

    // MARK: - Queues

    func addQueue(named name: String) -> UUID {
        let q = DownloadQueue(name: name, maxConcurrent: settings.data.maxSimultaneousDownloads)
        queues.append(q)
        saveNow()
        return q.id
    }

    func removeQueue(_ id: UUID) {
        guard let q = queue(id), !q.isMain else { return }
        stopQueue(id)
        queues.removeAll { $0.id == id }
        for i in items.indices where items[i].queueID == id { items[i].queueID = nil }
        saveNow()
    }

    func updateQueue(_ queue: DownloadQueue) {
        guard let i = queues.firstIndex(where: { $0.id == queue.id }) else { return }
        queues[i] = queue
        saveNow()
        if runningQueues.contains(queue.id) { processQueues() }
    }

    func move(_ ids: Set<UUID>, toQueue queueID: UUID?) {
        var order = queueID.map { nextQueueOrder($0) } ?? 0
        for item in items where ids.contains(item.id) {
            guard let i = index(of: item.id) else { continue }
            items[i].queueID = queueID
            items[i].queueOrder = order
            order += 1
        }
        saveNow()
        processQueues()
    }

    func itemsInQueue(_ queueID: UUID) -> [DownloadItem] {
        items.filter { $0.queueID == queueID }.sorted { $0.queueOrder < $1.queueOrder }
    }

    func moveInQueue(_ id: UUID, up: Bool) {
        guard let item = item(id), let q = item.queueID else { return }
        var list = itemsInQueue(q)
        guard let pos = list.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? pos - 1 : pos + 1
        guard target >= 0, target < list.count else { return }
        list.swapAt(pos, target)
        for (n, entry) in list.enumerated() {
            if let i = index(of: entry.id) { items[i].queueOrder = n + 1 }
        }
        saveNow()
    }

    func startQueue(_ id: UUID) {
        guard queue(id) != nil else { return }
        runningQueues.insert(id)
        queueExcluded[id] = []
        for item in items where item.queueID == id { queueAttempts[item.id] = 0 }
        processQueues()
    }

    func stopQueue(_ id: UUID) {
        runningQueues.remove(id)
        for item in items where item.queueID == id && startedByQueue.contains(item.id) {
            pause(item.id)
        }
    }

    func processQueues() {
        for q in queues where runningQueues.contains(q.id) {
            let queued = itemsInQueue(q.id)
            let excluded = queueExcluded[q.id] ?? []
            var running = queued.filter { engines[$0.id] != nil }.count
            let candidates = queued.filter { item in
                engines[item.id] == nil
                    && !excluded.contains(item.id)
                    && item.status != .completed
                    && (queueAttempts[item.id] ?? 0) < 2
            }
            for candidate in candidates where running < max(1, q.maxConcurrent) {
                start(candidate.id, fromQueue: true)
                running += 1
            }
            if running == 0 {
                runningQueues.remove(q.id)
                queueFinished(q)
            }
        }
    }

    private func queueFinished(_ queue: DownloadQueue) {
        if settings.data.notifyOnComplete {
            SystemActions.notify(title: String(localized: "Queue finished"), body: queue.displayName)
        }
        switch queue.schedule.afterCompletion {
        case .none:
            break
        case .quitApp, .sleep, .shutdown:
            WindowManager.shared.showCountdown(queue.schedule.afterCompletion)
        }
    }

    private func checkSchedules() {
        let now = Date()
        let cal = Calendar.current
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let weekday = cal.component(.weekday, from: now)
        let day = "\(cal.component(.year, from: now))-\(cal.ordinality(of: .day, in: .year, for: now) ?? 0)"
        for q in queues {
            let s = q.schedule
            if s.startEnabled, s.weekdays.contains(weekday), minutes == s.startMinutes {
                let key = "\(q.id.uuidString)-start"
                if lastScheduleFire[key] != day {
                    lastScheduleFire[key] = day
                    startQueue(q.id)
                }
            }
            if s.stopEnabled, minutes == s.stopMinutes, runningQueues.contains(q.id) {
                let key = "\(q.id.uuidString)-stop"
                if lastScheduleFire[key] != day {
                    lastScheduleFire[key] = day
                    stopQueue(q.id)
                }
            }
        }
    }

    // MARK: - Import / export

    func importList(from url: URL) {
        let decoded = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        guard let text = decoded else { return }
        let requests = ListFormat.parse(text)
        if !requests.isEmpty { WindowManager.shared.showLinks(requests) }
    }

    func export(_ items: [DownloadItem], to url: URL, ef2: Bool) {
        let text = ef2 ? ListFormat.exportEF2(items) : ListFormat.exportText(items)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - System integration

    private func updateActivity() {
        let busy = !engines.isEmpty
        if busy && settings.data.preventSleep {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                                 reason: "MacOS Download Manager is downloading files")
            }
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        NSApp?.dockTile.badgeLabel = engines.isEmpty ? nil : "\(engines.count)"
    }
}
