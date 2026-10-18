import Foundation

// MARK: - Download status

enum DownloadStatus: String, Codable, CaseIterable {
    case queued
    case connecting
    case downloading
    case paused
    case completed
    case failed
    case assembling

    var isActive: Bool {
        self == .connecting || self == .downloading || self == .assembling
    }

    var title: String {
        switch self {
        case .queued: return String(localized: "Queued")
        case .connecting: return String(localized: "Connecting…")
        case .downloading: return String(localized: "Downloading")
        case .paused: return String(localized: "Paused")
        case .completed: return String(localized: "Complete")
        case .failed: return String(localized: "Error")
        case .assembling: return String(localized: "Merging…")
        }
    }
}

enum DownloadKind: String, Codable {
    case http
    case hls
    /// A video/audio page (YouTube, …) resolved with yt-dlp; video and audio may be separate streams.
    case media
}

/// Progress of one stream (video or audio) of a `.media` download.
struct MediaPartState: Codable, Equatable {
    var formatID: String
    var ext: String = ""
    var totalBytes: Int64 = -1
    var downloadedBytes: Int64 = 0
    var segments: [Segment] = []
    var done: Bool = false
}

// MARK: - Segment (one byte range downloaded by one connection)

struct Segment: Codable, Identifiable, Equatable {
    var id: Int
    /// First byte of the range (inclusive).
    var start: Int64
    /// Last byte of the range (inclusive). -1 means "until end of stream" (unknown size).
    var end: Int64
    /// Number of bytes already written for this range, counted from `start`.
    var downloaded: Int64

    var current: Int64 { start + downloaded }

    var length: Int64 { end >= 0 ? end - start + 1 : -1 }

    var remaining: Int64 {
        guard end >= 0 else { return Int64.max }
        return max(0, end - start + 1 - downloaded)
    }

    var isComplete: Bool {
        end >= 0 && downloaded >= end - start + 1
    }
}

// MARK: - Download item

struct DownloadItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var url: URL
    var fileName: String
    var directory: String
    var category: String = "General"
    var kind: DownloadKind = .http
    var status: DownloadStatus = .queued
    var totalBytes: Int64 = -1
    var downloadedBytes: Int64 = 0
    var resumable: Bool = true
    var segments: [Segment] = []
    var tempPath: String? = nil
    var dateAdded: Date = Date()
    var lastTry: Date? = nil
    var dateCompleted: Date? = nil
    var note: String = ""
    var referer: String? = nil
    var cookies: String? = nil
    var userAgent: String? = nil
    var username: String? = nil
    var errorMessage: String? = nil
    var queueID: UUID? = nil
    var queueOrder: Int = 0
    var hlsVariantURL: URL? = nil
    var hlsDoneSegments: [Int] = []
    var hlsSegmentCount: Int = 0
    /// True when the file name was derived automatically and may be replaced by the server-provided name.
    var autoName: Bool = true
    /// yt-dlp format selection for `.media` downloads, e.g. "137+140".
    var mediaFormat: String? = nil
    var mediaParts: [MediaPartState] = []

    var filePath: String {
        (directory as NSString).appendingPathComponent(fileName)
    }

    var progress: Double {
        if status == .completed { return 1 }
        if kind == .hls, hlsSegmentCount > 0 {
            return min(1, Double(hlsDoneSegments.count) / Double(hlsSegmentCount))
        }
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }

    var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    var lastTryDate: Date { lastTry ?? dateAdded }

    var statusSortKey: Double {
        status == .completed ? 2 : progress
    }
}

// MARK: - Category

struct DownloadCategory: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var icon: String
    var extensions: [String]
    var folder: String

    var displayName: String {
        NSLocalizedString(name, comment: "Category name")
    }
}

// MARK: - Queue & scheduler

enum AfterQueueAction: String, Codable, CaseIterable, Identifiable {
    case none
    case quitApp
    case sleep
    case shutdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "Do nothing")
        case .quitApp: return String(localized: "Quit MacOS Download Manager")
        case .sleep: return String(localized: "Put the Mac to sleep")
        case .shutdown: return String(localized: "Shut down the Mac")
        }
    }
}

struct QueueSchedule: Codable, Hashable {
    var startEnabled: Bool = false
    /// Minutes since midnight.
    var startMinutes: Int = 120
    /// Calendar weekdays (1 = Sunday … 7 = Saturday).
    var weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    var stopEnabled: Bool = false
    var stopMinutes: Int = 420
    var startOnLaunch: Bool = false
    var afterCompletion: AfterQueueAction = .none
}

struct DownloadQueue: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var maxConcurrent: Int = 3
    var schedule: QueueSchedule = QueueSchedule()
    var isMain: Bool = false

    var displayName: String {
        isMain ? String(localized: "Main Download Queue") : name
    }
}

// MARK: - Runtime info (not persisted)

struct RuntimeStats: Equatable {
    var speed: Double = 0
    var connections: Int = 0
    var activeSegments: [Int] = []

    func eta(for item: DownloadItem) -> Double? {
        guard speed > 1, item.totalBytes > 0 else { return nil }
        return Double(max(0, item.totalBytes - item.downloadedBytes)) / speed
    }
}

/// A download request coming from the browser, the clipboard, drag & drop or the Add URL dialog.
struct CaptureRequest: Identifiable, Equatable {
    var id: UUID = UUID()
    var url: URL
    var referer: String? = nil
    var cookies: String? = nil
    var userAgent: String? = nil
    var suggestedName: String? = nil
    var fileSize: Int64? = nil
    var mime: String? = nil
    var username: String? = nil
    var password: String? = nil
}

// MARK: - Codable helpers

enum CodableDefaults {
    /// Decodes `T` from `json`, filling every key that is missing with the value from `defaults`.
    /// Keeps saved data readable after new properties are added in later versions.
    static func decode<T: Codable>(_ type: T.Type, from json: Any, defaults: T) -> T? {
        guard let saved = json as? [String: Any],
              let defData = try? JSONEncoder().encode(defaults),
              var merged = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any] else {
            return nil
        }
        for (key, value) in saved { merged[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
