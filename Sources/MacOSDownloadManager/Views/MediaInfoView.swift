import SwiftUI
import AppKit

/// Sites whose pages are handled as video pages (through yt-dlp) instead of plain file links.
enum MediaSites {
    static func isVideoPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("youtube.com") {
            return path.hasPrefix("/watch") || path.hasPrefix("/shorts/") || path.hasPrefix("/live/") || path.hasPrefix("/embed/")
        }
        if on("youtu.be") || on("vimeo.com") || on("dailymotion.com") || on("dai.ly") || on("tiktok.com")
            || on("twitch.tv") || on("soundcloud.com") || on("bilibili.com") || on("fb.watch") {
            return path.count > 1
        }
        if on("facebook.com") { return path.contains("/videos/") || path.hasPrefix("/watch") || path.hasPrefix("/reel") }
        if on("instagram.com") { return path.hasPrefix("/reel") || path.hasPrefix("/p/") || path.hasPrefix("/tv/") }
        if on("x.com") || on("twitter.com") { return path.contains("/status/") }
        return false
    }
}

/// "Download video" window: reads the page with yt-dlp and lets the user pick a quality.
struct MediaInfoView: View {
    let pageURL: URL
    let windowKey: String

    @EnvironmentObject var manager: DownloadManager
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var tools = MediaTools.shared

    private enum Phase: Equatable {
        case needsComponents
        case loading
        case ready
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var info: YTDLInfo?
    @State private var options: [MediaOption] = []
    @State private var selected = ""
    @State private var fileName = ""
    @State private var folder = ""
    @State private var folderEdited = false
    @State private var initialized = false

    private var selectedOption: MediaOption? {
        options.first { $0.spec == selected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch phase {
            case .needsComponents:
                componentsPanel
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if tools.installing && !tools.installStatus.isEmpty {
                        Text(verbatim: tools.installStatus).foregroundStyle(.secondary)
                    } else {
                        Text("Reading the video page…").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            case .failed(let message):
                failurePanel(message)
            case .ready:
                readyForm
            }
            buttons
        }
        .padding(20)
        .frame(width: 620)
        .onAppear(perform: setup)
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let thumb = info?.thumbnail, let url = URL(string: thumb) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.primary.opacity(0.06)
                    }
                } else {
                    ZStack {
                        Color.primary.opacity(0.06)
                        Image(systemName: "play.rectangle.fill").font(.system(size: 30)).foregroundStyle(.red)
                    }
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: info?.title ?? pageURL.host ?? pageURL.absoluteString)
                    .font(.headline)
                    .lineLimit(3)
                if let uploader = info?.uploader {
                    Text(verbatim: uploader).foregroundStyle(.secondary)
                }
                if let duration = info?.duration, duration > 0 {
                    Label {
                        Text(verbatim: Fmt.duration(duration))
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(verbatim: pageURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var componentsPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("To download videos from YouTube and other sites, MacOS Download Manager uses the free open-source tools yt-dlp, Deno and ffmpeg. They are downloaded once from their official pages and checked before use.")
                    .fixedSize(horizontal: false, vertical: true)
                if tools.installing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(verbatim: tools.installStatus).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Download Components") { installAndLoad() }
                        .buttonStyle(.borderedProminent)
                }
                if let error = tools.lastError {
                    Text(verbatim: error).foregroundStyle(.red).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func failurePanel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(verbatim: message).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Picker("Use cookies from", selection: $settings.data.mediaCookiesBrowser) {
                    ForEach(CookieBrowser.all, id: \.id) { b in
                        Text(verbatim: b.title).tag(b.id)
                    }
                }
                .frame(maxWidth: 300)
                Button("Try Again") { load() }
            }
            Text("Some videos (age-restricted, members-only, or when the site asks to confirm you are not a bot) need the cookies of a browser where you are signed in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readyForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quality").font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(options) { option in
                        OptionRow(option: option, selected: option.spec == selected) {
                            choose(option)
                        }
                    }
                }
            }
            .frame(maxHeight: 230)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            if MediaTools.findFFmpeg() == nil {
                Text("ffmpeg could not be downloaded, so qualities above 1080p (VP9/AV1) are hidden. Download it in Options → Video, or install it with Homebrew (brew install ffmpeg).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let option = selectedOption, !option.compatible {
                Text("VP9/AV1 videos do not play in QuickTime on every Mac: VLC or IINA play them. Choose an H.264 quality for a file that plays everywhere.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Save As").gridColumnAlignment(.trailing)
                    TextField("File name", text: $fileName).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Folder")
                    HStack {
                        Text(verbatim: folder)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                        Button("Browse…") { browse() }
                    }
                }
            }
        }
    }

    private var buttons: some View {
        HStack {
            if phase == .ready {
                Menu("Download Later") {
                    ForEach(manager.queues) { queue in
                        Button(queue.displayName) { add(start: false, queue: queue.id) }
                    }
                    Divider()
                    Button("Add without a queue") { add(start: false, queue: nil) }
                }
                .fixedSize()
            }
            Spacer()
            Button("Cancel") { WindowManager.shared.close(windowKey) }
                .keyboardShortcut(.cancelAction)
            Button("Start Download") { add(start: true, queue: nil) }
                .keyboardShortcut(.defaultAction)
                .disabled(phase != .ready || selectedOption == nil || fileName.isEmpty)
        }
    }

    // MARK: Actions

    private func setup() {
        guard !initialized else { return }
        initialized = true
        tools.refreshStatus()
        if tools.isComplete {
            load()
        } else if tools.isInstalled && MediaTools.findFFmpeg() != nil {
            load() // only the yt-dlp upgrade is pending: it happens in the background
            tools.upgradeInBackgroundIfNeeded()
        } else if tools.isInstalled {
            // ffmpeg (new in 1.1.3) is downloaded once, before the qualities are listed.
            phase = .loading
            Task {
                _ = await tools.ensureFFmpeg()
                load()
            }
        } else {
            phase = .needsComponents
        }
    }

    private func installAndLoad() {
        Task {
            do {
                try await tools.install()
                load()
            } catch {
                phase = .needsComponents
            }
        }
    }

    private func load() {
        phase = .loading
        let cookies = settings.data.mediaCookiesBrowser
        let url = pageURL
        Task {
            do {
                // Already read in the background while the page was open, or read now.
                let result = try await MediaInfoCache.shared.info(for: url, cookies: cookies)
                let list = MediaPlanner.options(for: result, ffmpeg: MediaTools.findFFmpeg() != nil)
                guard !list.isEmpty else {
                    phase = .failed(String(localized: "No downloadable video was found on this page"))
                    return
                }
                info = result
                options = list
                let preferred = MediaPlanner.preferred(list, maxHeight: settings.data.mediaMaxHeight) ?? list[0]
                selected = preferred.spec
                let base = FileNameUtils.sanitize(result.title ?? "video")
                fileName = (base.isEmpty ? "video" : base) + "." + preferred.ext
                if !folderEdited {
                    folder = settings.folder(forCategory: settings.categoryName(forFileName: fileName))
                }
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func choose(_ option: MediaOption) {
        selected = option.spec
        let base = (fileName as NSString).deletingPathExtension
        fileName = (base.isEmpty ? "video" : base) + "." + option.ext
        if !folderEdited {
            folder = settings.folder(forCategory: settings.categoryName(forFileName: fileName))
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
            folderEdited = true
        }
    }

    private func add(start: Bool, queue: UUID?) {
        guard let option = selectedOption else { return }
        var name = FileNameUtils.sanitize(fileName)
        if (name as NSString).pathExtension.lowercased() != option.ext {
            name = (name as NSString).deletingPathExtension + "." + option.ext
        }
        var item = DownloadItem(url: pageURL, fileName: name, directory: folder)
        item.kind = .media
        item.mediaFormat = option.spec
        item.category = settings.categoryName(forFileName: name)
        item.note = info?.title ?? ""
        item.totalBytes = option.size ?? -1
        item.autoName = false
        item.queueID = queue
        manager.add(item, password: nil, start: start)
        WindowManager.shared.close(windowKey)
    }
}

private struct OptionRow: View {
    let option: MediaOption
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Image(systemName: option.audioOnly ? "music.note" : "film")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(verbatim: option.title)
                    .fontWeight(selected ? .semibold : .regular)
                    .frame(minWidth: 110, alignment: .leading)
                Text(verbatim: option.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CookieBrowser {
    let id: String
    let title: String

    static let all: [CookieBrowser] = [
        CookieBrowser(id: "", title: String(localized: "None")),
        CookieBrowser(id: "safari", title: "Safari"),
        CookieBrowser(id: "chrome", title: "Google Chrome"),
        CookieBrowser(id: "brave", title: "Brave"),
        CookieBrowser(id: "edge", title: "Microsoft Edge"),
        CookieBrowser(id: "firefox", title: "Firefox"),
        CookieBrowser(id: "opera", title: "Opera"),
        CookieBrowser(id: "vivaldi", title: "Vivaldi")
    ]
}
