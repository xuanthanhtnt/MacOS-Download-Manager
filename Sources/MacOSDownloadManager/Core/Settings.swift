import Foundation
import Combine

enum ProxyMode: String, Codable, CaseIterable, Identifiable {
    case none
    case system
    case http
    case socks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "No proxy (direct connection)")
        case .system: return String(localized: "Use system proxy settings")
        case .http: return String(localized: "HTTP/HTTPS proxy")
        case .socks: return String(localized: "SOCKS5 proxy")
        }
    }
}

enum DuplicateAction: String, Codable, CaseIterable, Identifiable {
    case rename
    case overwrite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rename: return String(localized: "Add a number to the new file name")
        case .overwrite: return String(localized: "Overwrite the existing file")
        }
    }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case english
    case vietnamese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "System default")
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        }
    }
}

struct SiteLogin: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// Host or host suffix, e.g. "example.com" or "files.example.com".
    var site: String
    var username: String

    func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let pattern = site.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ *."))
        guard !pattern.isEmpty else { return false }
        return host == pattern || host.hasSuffix("." + pattern)
    }
}

struct AppSettingsData: Codable, Equatable {
    // Connection
    var maxConnections: Int = 8
    var maxSimultaneousDownloads: Int = 3
    var timeoutSeconds: Int = 30
    var retryCount: Int = 5
    var speedLimitEnabled: Bool = false
    var speedLimitKBps: Int = 1024
    var userAgent: String = AppSettingsData.defaultUserAgent

    // Dialogs & behaviour
    var showFileInfoDialog: Bool = true
    var showProgressDialog: Bool = true
    var showCompleteDialog: Bool = true
    var monitorClipboard: Bool = true
    var showMenuBarIcon: Bool = true
    /// Quit from the Dock / ⌘Q keeps the app running in the menu bar; the menu bar's Quit really quits.
    var keepRunningInMenuBar: Bool = true
    var showDropTarget: Bool = false
    var preventSleep: Bool = true
    var language: AppLanguage = .system

    // Browser integration
    var browserIntegration: Bool = true
    var serverPort: Int = 9614
    var captureExtensions: [String] = AppSettingsData.defaultCaptureExtensions

    // Proxy
    var proxyMode: ProxyMode = .system
    var proxyHost: String = ""
    var proxyPort: Int = 8080

    // Save to
    var categories: [DownloadCategory] = AppSettingsData.defaultCategories()
    var duplicateAction: DuplicateAction = .rename

    // After download
    var notifyOnComplete: Bool = true
    var playSoundOnComplete: Bool = true
    var openFolderOnComplete: Bool = false
    var runCommandAfterDownload: Bool = false
    var commandAfterDownload: String = ""

    // Site logins (passwords live in the Keychain)
    var siteLogins: [SiteLogin] = []

    // Video downloads (yt-dlp)
    /// Browser whose cookies yt-dlp may use ("" = none): safari, chrome, brave, edge, firefox, opera, vivaldi.
    var mediaCookiesBrowser: String = ""
    /// Preferred maximum video height (0 = best available).
    var mediaMaxHeight: Int = 0
    /// Read the qualities of an open video page in the background (the list then appears at once).
    var mediaPrefetch: Bool = true

    static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static var downloadsFolder: String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
    }

    static func defaultCategories() -> [DownloadCategory] {
        let base = downloadsFolder
        func sub(_ name: String) -> String { (base as NSString).appendingPathComponent(name) }
        return [
            DownloadCategory(name: "General", icon: "doc", extensions: [], folder: base),
            DownloadCategory(name: "Compressed", icon: "doc.zipper",
                             extensions: ["zip", "rar", "7z", "gz", "tgz", "bz2", "xz", "tar", "z", "lzh", "arj", "cab", "ace", "sit", "sitx", "zst"],
                             folder: sub("Compressed")),
            DownloadCategory(name: "Documents", icon: "doc.text",
                             extensions: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pps", "txt", "rtf", "odt", "ods", "odp", "epub", "mobi", "csv", "pages", "numbers", "key", "djvu"],
                             folder: sub("Documents")),
            DownloadCategory(name: "Music", icon: "music.note",
                             extensions: ["mp3", "wav", "wma", "mpa", "ram", "ra", "aac", "aif", "aiff", "m4a", "flac", "ogg", "opus", "mid", "midi", "ape"],
                             folder: sub("Music")),
            DownloadCategory(name: "Programs", icon: "shippingbox",
                             extensions: ["dmg", "pkg", "mpkg", "exe", "msi", "apk", "ipa", "deb", "rpm", "bin", "iso", "img", "jar", "appimage"],
                             folder: sub("Programs")),
            DownloadCategory(name: "Video", icon: "film",
                             extensions: ["mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "3gp", "ts", "m3u8", "rm", "rmvb", "ogv", "vob", "qt", "asf"],
                             folder: sub("Video"))
        ]
    }

    static var defaultCaptureExtensions: [String] {
        var all: [String] = []
        for c in defaultCategories() { all.append(contentsOf: c.extensions) }
        return all
    }
}

/// Persistent, observable application settings.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private static let key = "MDM.settings.v1"

    private var storage: AppSettingsData

    /// Emits the new settings after every real change (and the current value on subscription).
    let changes: CurrentValueSubject<AppSettingsData, Never>

    /// Writing the same value again is ignored, so SwiftUI bindings that re-assign values
    /// during view updates cannot trigger endless update cycles.
    var data: AppSettingsData {
        get { storage }
        set {
            guard newValue != storage else { return }
            objectWillChange.send()
            storage = newValue
            save()
            changes.send(newValue)
        }
    }

    private init() {
        let loaded = SettingsStore.load()
        storage = loaded
        changes = CurrentValueSubject(loaded)
        applyLanguage()
    }

    private static func load() -> AppSettingsData {
        let defaults = AppSettingsData()
        guard let raw = UserDefaults.standard.data(forKey: key),
              let json = try? JSONSerialization.jsonObject(with: raw),
              let decoded = CodableDefaults.decode(AppSettingsData.self, from: json, defaults: defaults) else {
            return defaults
        }
        return decoded
    }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(raw, forKey: SettingsStore.key)
        }
        applyLanguage()
    }

    /// The language override takes effect the next time the app starts.
    private func applyLanguage() {
        switch data.language {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        case .vietnamese: UserDefaults.standard.set(["vi"], forKey: "AppleLanguages")
        }
    }

    // MARK: Helpers

    func category(named name: String) -> DownloadCategory {
        data.categories.first { $0.name == name } ?? data.categories.first
            ?? AppSettingsData.defaultCategories()[0]
    }

    func categoryName(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return "General" }
        return data.categories.first { $0.extensions.contains(ext) }?.name ?? "General"
    }

    func folder(forCategory name: String) -> String {
        category(named: name).folder
    }

    func shouldCapture(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return data.captureExtensions.contains(ext)
    }

    func siteLogin(for url: URL) -> SiteLogin? {
        data.siteLogins.first { $0.matches(url) }
    }

    var proxyDictionary: [AnyHashable: Any]? {
        switch data.proxyMode {
        case .system:
            return nil
        case .none:
            return [:]
        case .http:
            guard !data.proxyHost.isEmpty else { return nil }
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: data.proxyHost,
                kCFNetworkProxiesHTTPPort as String: data.proxyPort,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: data.proxyHost,
                kCFNetworkProxiesHTTPSPort as String: data.proxyPort
            ]
        case .socks:
            guard !data.proxyHost.isEmpty else { return nil }
            return [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: data.proxyHost,
                kCFNetworkProxiesSOCKSPort as String: data.proxyPort
            ]
        }
    }
}
