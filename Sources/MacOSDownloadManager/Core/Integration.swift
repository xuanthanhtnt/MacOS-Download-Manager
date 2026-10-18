import Foundation
import AppKit
import Network
import UserNotifications

// MARK: - Local server used by the browser extension

/// A tiny HTTP server bound to the loopback interface. The MacOS Download Manager browser extension posts
/// captured downloads to it. Requests coming from web pages (an http/https Origin) are rejected.
final class BrowserBridgeServer {
    static let shared = BrowserBridgeServer()

    enum Message {
        case download(CaptureRequest)
        case links([URL], referer: String?)
    }

    var onMessage: ((Message) -> Void)?
    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var port: Int = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mdm.bridge")

    func start(port: Int) {
        stop()
        self.port = port
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            lastError = "Invalid port"
            return
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback
            let l = try NWListener(using: params, on: nwPort)
            l.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.lastError = nil
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = self.parse(buffer) {
                self.respond(to: request, on: connection)
                return
            }
            if isComplete || error != nil || buffer.count > 4_000_000 {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        return Request(method: String(requestLine[0]).uppercased(),
                       path: String(requestLine[1]),
                       headers: headers,
                       body: Data(body))
    }

    private func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin = origin?.lowercased(), !origin.isEmpty else { return true }
        return origin.hasPrefix("chrome-extension://")
            || origin.hasPrefix("moz-extension://")
            || origin.hasPrefix("safari-web-extension://")
            || origin.hasPrefix("extension://")
    }

    private func respond(to request: Request, on connection: NWConnection) {
        var status = "200 OK"
        var body: [String: Any]? = ["ok": true]
        var message: Message?
        let origin = request.headers["origin"]
        let allowed = isAllowedOrigin(origin)

        if !allowed {
            status = "403 Forbidden"
            body = ["ok": false, "error": "forbidden origin"]
        } else if request.method == "OPTIONS" {
            // CORS / Private Network Access preflight from the extension (some browsers, e.g. Brave, send one).
            status = "204 No Content"
            body = nil
        } else if request.method == "GET" && request.path.hasPrefix("/ping") {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            body = ["ok": true, "app": "MacOS Download Manager", "version": version]
        } else if request.method == "POST" {
            let contentType = request.headers["content-type"]?.lowercased() ?? ""
            if !contentType.contains("application/json") {
                status = "415 Unsupported Media Type"
                body = ["ok": false, "error": "json required"]
            } else if let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] {
                if request.path.hasPrefix("/download"), let m = downloadMessage(json) {
                    message = m
                } else if request.path.hasPrefix("/links"), let m = linksMessage(json) {
                    message = m
                } else {
                    status = "400 Bad Request"
                    body = ["ok": false, "error": "invalid request"]
                }
            } else {
                status = "400 Bad Request"
                body = ["ok": false, "error": "invalid json"]
            }
        } else {
            status = "404 Not Found"
            body = ["ok": false]
        }

        let payload = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "HTTP/1.1 \(status)\r\n"
        if allowed, let origin, !origin.isEmpty {
            head += "Access-Control-Allow-Origin: \(origin)\r\n"
            head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            head += "Access-Control-Allow-Headers: Content-Type\r\n"
            head += "Access-Control-Allow-Private-Network: true\r\n"
            head += "Access-Control-Max-Age: 600\r\n"
            head += "Vary: Origin\r\n"
        }
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(payload.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(payload)
        // Send the answer completely (with a clean end of stream) before closing, so the browser always
        // receives it; only then hand the link to the app.
        let received = message
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            if let received {
                DispatchQueue.main.async { self?.onMessage?(received) }
            }
            self?.queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
        })
    }

    private func downloadMessage(_ json: [String: Any]) -> Message? {
        guard let s = json["url"] as? String, let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme) else { return nil }
        var req = CaptureRequest(url: url)
        req.referer = json["referrer"] as? String ?? json["referer"] as? String
        req.cookies = json["cookies"] as? String
        req.userAgent = json["userAgent"] as? String
        if let name = json["fileName"] as? String, !name.isEmpty {
            req.suggestedName = FileNameUtils.sanitize((name as NSString).lastPathComponent)
        }
        if let size = json["fileSize"] as? NSNumber, size.int64Value > 0 { req.fileSize = size.int64Value }
        req.mime = json["mime"] as? String
        return .download(req)
    }

    private func linksMessage(_ json: [String: Any]) -> Message? {
        guard let list = json["urls"] as? [String] else { return nil }
        let urls = list.compactMap(URL.init(string:)).filter { ["http", "https", "ftp"].contains($0.scheme?.lowercased() ?? "") }
        guard !urls.isEmpty else { return nil }
        return .links(urls, referer: json["referrer"] as? String)
    }
}

// MARK: - Clipboard monitor

final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    var onURL: ((URL) -> Void)?
    var shouldCapture: ((URL) -> Bool)?
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var lastURL: String?

    func start() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Call before MacOS Download Manager itself writes to the pasteboard so the change is not captured.
    func ignoreCurrentChange() {
        lastChange = NSPasteboard.general.changeCount
    }

    private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count < 4096, !text.contains(" "), !text.contains("\n"),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme),
              text != lastURL else { return }
        guard shouldCapture?(url) ?? false else { return }
        lastURL = text
        onURL?(url)
    }
}

// MARK: - System actions

enum SystemActions {
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func playCompletionSound() {
        NSSound(named: NSSound.Name("Glass"))?.play()
    }

    static func revealInFinder(_ path: String) {
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            let dir = (path as NSString).deletingLastPathComponent
            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
        }
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Runs a user-defined command (e.g. an antivirus scanner) with the downloaded file as argument.
    static func runCommand(_ command: String, filePath: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", trimmed + " \"$1\"", "mdm", filePath]
        try? process.run()
    }

    static func sleepMac() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        try? process.run()
    }

    static func shutDownMac() {
        let script = NSAppleScript(source: "tell application \"System Events\" to shut down")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }
}
