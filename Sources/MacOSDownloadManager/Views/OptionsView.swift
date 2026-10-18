import SwiftUI
import AppKit
import ServiceManagement

enum OptionsTab: String, CaseIterable, Identifiable {
    case general, connection, saveTo, fileTypes, proxy, logins, browser, video, afterDownload

    var id: String { rawValue }
}

struct OptionsView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var tab: OptionsTab

    init(initialTab: OptionsTab) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralOptions()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(OptionsTab.general)
            ConnectionOptions()
                .tabItem { Label("Connection", systemImage: "network") }
                .tag(OptionsTab.connection)
            SaveToOptions()
                .tabItem { Label("Save To", systemImage: "folder") }
                .tag(OptionsTab.saveTo)
            FileTypesOptions()
                .tabItem { Label("File Types", systemImage: "doc.badge.gearshape") }
                .tag(OptionsTab.fileTypes)
            ProxyOptions()
                .tabItem { Label("Proxy", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(OptionsTab.proxy)
            SiteLoginsOptions()
                .tabItem { Label("Site Logins", systemImage: "key") }
                .tag(OptionsTab.logins)
            BrowserOptions()
                .tabItem { Label("Browser", systemImage: "safari") }
                .tag(OptionsTab.browser)
            VideoOptions()
                .tabItem { Label("Video", systemImage: "play.rectangle") }
                .tag(OptionsTab.video)
            AfterDownloadOptions()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(OptionsTab.afterDownload)
        }
        .padding(14)
        .frame(width: 780, height: 540)
        .onReceive(NotificationCenter.default.publisher(for: .turboSelectOptionsTab)) { note in
            if let t = note.object as? OptionsTab { tab = t }
        }
    }
}

// MARK: - General

private struct GeneralOptions: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch MacOS Download Manager at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let loginError {
                    Text(verbatim: loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show icon in the menu bar", isOn: $settings.data.showMenuBarIcon)
                Toggle("Show the floating drop target", isOn: $settings.data.showDropTarget)
                Toggle("Keep the Mac awake while downloading", isOn: $settings.data.preventSleep)
            }
            Section("Capture") {
                Toggle("Monitor the clipboard for download links", isOn: $settings.data.monitorClipboard)
                Toggle("Show the \"Download File Info\" dialog before downloading", isOn: $settings.data.showFileInfoDialog)
                Toggle("Show the download progress dialog", isOn: $settings.data.showProgressDialog)
                Toggle("Show the \"Download complete\" dialog", isOn: $settings.data.showCompleteDialog)
            }
            Section("Language") {
                Picker("Language", selection: $settings.data.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(verbatim: lang.title).tag(lang)
                    }
                }
                Text("The new language is used the next time MacOS Download Manager starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Connection

private struct ConnectionOptions: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.data.maxConnections, in: 1...32) {
                    LabeledContent("Max. connections per download") {
                        Text(verbatim: "\(settings.data.maxConnections)").monospacedDigit()
                    }
                }
                Stepper(value: $settings.data.maxSimultaneousDownloads, in: 1...20) {
                    LabeledContent("Default downloads at the same time in a queue") {
                        Text(verbatim: "\(settings.data.maxSimultaneousDownloads)").monospacedDigit()
                    }
                }
                Stepper(value: $settings.data.retryCount, in: 0...50) {
                    LabeledContent("Retries for each connection") {
                        Text(verbatim: "\(settings.data.retryCount)").monospacedDigit()
                    }
                }
                Stepper(value: $settings.data.timeoutSeconds, in: 5...300, step: 5) {
                    LabeledContent("Connection timeout (seconds)") {
                        Text(verbatim: "\(settings.data.timeoutSeconds)").monospacedDigit()
                    }
                }
            } footer: {
                Text("MacOS Download Manager opens several connections to the server and splits the file dynamically between them. 8–16 connections work well for most servers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Speed limiter") {
                Toggle("Limit the total download speed", isOn: $settings.data.speedLimitEnabled)
                HStack {
                    Text("Maximum speed")
                    Spacer()
                    TextField("", value: $settings.data.speedLimitKBps, format: .number)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                    Text(verbatim: "KB/s")
                }
                .disabled(!settings.data.speedLimitEnabled)
            }
            Section("Identity") {
                TextField("User-Agent", text: $settings.data.userAgent)
                Button("Reset User-Agent") { settings.data.userAgent = AppSettingsData.defaultUserAgent }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Save to (categories)

private struct SaveToOptions: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var selected: String?
    @State private var newName = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                List(selection: $selected) {
                    ForEach(settings.data.categories) { c in
                        Label(c.displayName, systemImage: c.icon).tag(c.name)
                    }
                }
                .frame(width: 190)
                HStack {
                    TextField("New category", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        addCategory()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button {
                        removeSelected()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selected == nil || selected == "General")
                }
                .frame(width: 190)
            }
            if let name = selected, let index = settings.data.categories.firstIndex(where: { $0.name == name }) {
                CategoryEditor(category: $settings.data.categories[index])
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select a category to choose its folder and file extensions.")
                        .foregroundStyle(.secondary)
                    Divider()
                    Picker("If the file already exists", selection: $settings.data.duplicateAction) {
                        ForEach(DuplicateAction.allCases) { a in
                            Text(verbatim: a.title).tag(a)
                        }
                    }
                    Button("Restore default categories") {
                        settings.data.categories = AppSettingsData.defaultCategories()
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
    }

    private func addCategory() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !settings.data.categories.contains(where: { $0.name == name }) else { return }
        let folder = (AppSettingsData.downloadsFolder as NSString).appendingPathComponent(name)
        settings.data.categories.append(DownloadCategory(name: name, icon: "folder", extensions: [], folder: folder))
        selected = name
        newName = ""
    }

    private func removeSelected() {
        guard let name = selected, name != "General" else { return }
        settings.data.categories.removeAll { $0.name == name }
        selected = nil
    }
}

private struct CategoryEditor: View {
    @Binding var category: DownloadCategory
    @State private var extensionsText = ""
    @State private var loadedFor = ""

    var body: some View {
        Form {
            LabeledContent("Category") {
                Text(verbatim: category.displayName).fontWeight(.semibold)
            }
            LabeledContent("Save files to") {
                HStack {
                    Text(verbatim: category.folder)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Browse…") { browse() }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("File extensions (separated by spaces)")
                TextEditor(text: $extensionsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 90)
                    .onChange(of: extensionsText) { newValue in
                        category.extensions = newValue
                            .lowercased()
                            .components(separatedBy: CharacterSet(charactersIn: " ,;\n\t"))
                            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
                            .filter { !$0.isEmpty }
                    }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: category.name) { _ in load() }
    }

    private func load() {
        guard loadedFor != category.name else { return }
        loadedFor = category.name
        extensionsText = category.extensions.joined(separator: " ")
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: category.folder)
        if panel.runModal() == .OK, let url = panel.url {
            category.folder = url.path
        }
    }
}

// MARK: - File types

private struct FileTypesOptions: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .onChange(of: text) { newValue in
                        settings.data.captureExtensions = newValue.lowercased()
                            .components(separatedBy: CharacterSet(charactersIn: " ,;\n\t"))
                            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
                            .filter { !$0.isEmpty }
                    }
            } header: {
                Text("Automatically take over downloads of these file types (browser extension and clipboard):")
            }
            Button("Restore defaults") {
                settings.data.captureExtensions = AppSettingsData.defaultCaptureExtensions
                text = settings.data.captureExtensions.joined(separator: " ")
            }
        }
        .formStyle(.grouped)
        .onAppear { text = settings.data.captureExtensions.joined(separator: " ") }
    }
}

// MARK: - Proxy

private struct ProxyOptions: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Picker("Connection", selection: $settings.data.proxyMode) {
                ForEach(ProxyMode.allCases) { mode in
                    Text(verbatim: mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            if settings.data.proxyMode == .http || settings.data.proxyMode == .socks {
                TextField("Proxy server", text: $settings.data.proxyHost)
                TextField("Port", value: $settings.data.proxyPort, format: .number.grouping(.never))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Site logins

private struct SiteLoginsOptions: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var site = ""
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                if settings.data.siteLogins.isEmpty {
                    Text("No saved logins.").foregroundStyle(.secondary)
                }
                ForEach(settings.data.siteLogins) { login in
                    HStack {
                        Image(systemName: "key.fill").foregroundStyle(.secondary)
                        Text(verbatim: login.site).fontWeight(.medium)
                        Text(verbatim: login.username).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            Keychain.delete(account: "site-\(login.id.uuidString)")
                            settings.data.siteLogins.removeAll { $0.id == login.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("MacOS Download Manager uses these logins automatically when a server asks for a user name and password.")
            }
            Section("Add a login") {
                TextField("Site (e.g. files.example.com)", text: $site)
                TextField("User name", text: $user)
                SecureField("Password", text: $password)
                Button("Add") {
                    let login = SiteLogin(site: site.trimmingCharacters(in: .whitespaces), username: user)
                    Keychain.set(password, account: "site-\(login.id.uuidString)")
                    settings.data.siteLogins.append(login)
                    site = ""
                    user = ""
                    password = ""
                }
                .disabled(site.trimmingCharacters(in: .whitespaces).isEmpty || user.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Browser integration

private struct BrowserOptions: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var extensionStatus = ExtensionStatus.shared
    @State private var status = ""

    private var bookmarklet: String {
        "javascript:location.href='macosdm://add?url='+encodeURIComponent(location.href)"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable browser integration", isOn: $settings.data.browserIntegration)
                TextField("Local port", value: $settings.data.serverPort, format: .number.grouping(.never))
                HStack {
                    Button("Test connection") { test() }
                    Text(verbatim: status).foregroundStyle(.secondary)
                }
                LabeledContent("Installed extension") {
                    if let version = extensionStatus.version {
                        HStack(spacing: 6) {
                            Text(verbatim: version == ExtensionStatus.olderThanVersionReporting
                                 ? "≤ v" + version : "v" + version)
                            if extensionStatus.isOutdated {
                                Label("Outdated – update it", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            } else {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    } else {
                        Text("Not connected yet").foregroundStyle(.secondary)
                    }
                }
                if extensionStatus.isOutdated {
                    Text("The extension in your browser is older than the app. Click “Show Extension Folder in Finder”, then in the browser's extensions page remove the old MacOS Download Manager extension and load the new folder (Load unpacked). Reload the open YouTube tabs afterwards.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("The MacOS Download Manager extension sends captured downloads to MacOS Download Manager on 127.0.0.1. Only the extension can use this port; web pages are rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Install the extension") {
                Text("Chrome, Edge, Brave, Opera, Vivaldi, Arc: open the extensions page (chrome://extensions), turn on Developer mode, click \"Load unpacked\" and choose the \"chrome\" folder.")
                Text("Firefox: open about:debugging → This Firefox → \"Load Temporary Add-on…\" and choose manifest.json in the \"firefox\" folder.")
                Button("Show Extension Folder in Finder") { BrowserExtensionInstaller.reveal() }
            }
            Section("Safari and other browsers") {
                Text("Drag links onto the MacOS Download Manager window or the drop target, copy them to the clipboard, or create a bookmark with this address to send the current page to MacOS Download Manager:")
                HStack {
                    Text(verbatim: bookmarklet)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Button("Copy") {
                        ClipboardMonitor.shared.ignoreCurrentChange()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bookmarklet, forType: .string)
                        ClipboardMonitor.shared.ignoreCurrentChange()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { test() }
    }

    private func test() {
        let server = BrowserBridgeServer.shared
        if !settings.data.browserIntegration {
            status = String(localized: "Integration is turned off")
        } else if server.isRunning {
            status = String(format: NSLocalizedString("Listening on 127.0.0.1:%d", comment: ""), server.port)
        } else if let error = server.lastError {
            status = error
        } else {
            status = String(localized: "Starting…")
        }
    }
}

enum BrowserExtensionInstaller {
    private static var bundled: URL? {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension"),
              FileManager.default.fileExists(atPath: source.path) else { return nil }
        return source
    }

    /// Stable folder the browser loads the extension from (survives app updates).
    static var installedCopy: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacOS Download Manager", isDirectory: true)
        return base.appendingPathComponent("BrowserExtension", isDirectory: true)
    }

    private static func version(of folder: URL) -> String? {
        let manifest = folder.appendingPathComponent("chrome/manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    @discardableResult
    private static func copyBundled() -> Bool {
        guard let source = bundled else { return false }
        let fm = FileManager.default
        let target = installedCopy
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: target)
        return (try? fm.copyItem(at: source, to: target)) != nil
    }

    /// Called at launch: if the user loads the extension from the stable folder, refresh it after an app update,
    /// so the browser only needs a reload (↻) to get the new version.
    static func refreshInstalledCopyIfNeeded() {
        guard let source = bundled, FileManager.default.fileExists(atPath: installedCopy.path) else { return }
        if version(of: installedCopy) != version(of: source) {
            copyBundled()
        }
    }

    /// Copies the bundled extension to Application Support (a stable path the browser can load) and reveals it.
    static func reveal() {
        guard copyBundled() else {
            if let url = URL(string: "https://github.com/xuanthanhtnt/MacOS-Download-Manager/tree/main/BrowserExtension") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([installedCopy.appendingPathComponent("chrome")])
    }
}

// MARK: - Video downloads

private struct VideoOptions: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var tools = MediaTools.shared

    private let heights = [0, 2160, 1440, 1080, 720, 480, 360]

    var body: some View {
        Form {
            Section {
                LabeledContent("yt-dlp") {
                    Text(verbatim: tools.ytdlpVersion ?? String(localized: "Not installed"))
                        .foregroundStyle(tools.ytdlpVersion == nil ? Color.orange : Color.secondary)
                }
                LabeledContent("Deno") {
                    Text(verbatim: tools.denoVersion ?? String(localized: "Not installed"))
                        .foregroundStyle(tools.denoVersion == nil ? Color.orange : Color.secondary)
                }
                LabeledContent("FFmpeg") {
                    Text(verbatim: ffmpegText)
                        .foregroundStyle(tools.ffmpegPath == nil ? Color.orange : Color.secondary)
                }
                HStack {
                    if tools.installing {
                        ProgressView().controlSize(.small)
                        Text(verbatim: tools.installStatus).foregroundStyle(.secondary)
                    } else if tools.isInstalled && tools.ffmpegPath == nil {
                        Button("Download Missing Components") { Task { try? await tools.installMissing() } }
                            .buttonStyle(.borderedProminent)
                    } else if tools.isInstalled {
                        Button("Update yt-dlp") { Task { try? await tools.updateYtdlp() } }
                        Button("Download Components Again") { Task { try? await tools.install() } }
                    } else {
                        Button("Download Components") { Task { try? await tools.install() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let error = tools.lastError {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Components")
            } footer: {
                Text("yt-dlp reads video pages (YouTube and many other sites), Deno is the JavaScript runtime it needs for YouTube, and ffmpeg joins video and audio streams that macOS cannot join itself. All are free and open source: yt-dlp and Deno come from their official GitHub releases, ffmpeg from the signed macOS builds at ffmpeg.martin-riedl.de. Update yt-dlp when a site stops working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Preferences") {
                Picker("Preferred maximum quality", selection: $settings.data.mediaMaxHeight) {
                    ForEach(heights, id: \.self) { h in
                        Text(verbatim: h == 0 ? String(localized: "Best available") : "\(h)p").tag(h)
                    }
                }
                Picker("Use cookies from", selection: $settings.data.mediaCookiesBrowser) {
                    ForEach(CookieBrowser.all, id: \.id) { b in
                        Text(verbatim: b.title).tag(b.id)
                    }
                }
                Text("Cookies let yt-dlp open videos that need you to be signed in. macOS may ask for permission to read the browser's data; Safari needs Full Disk Access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { tools.refreshStatus() }
    }

    private var ffmpegText: String {
        guard let path = tools.ffmpegPath else { return String(localized: "Not installed") }
        let version = tools.ffmpegVersion ?? ""
        if path == tools.ffmpegToolPath { return version.isEmpty ? String(localized: "Installed") : version }
        return version.isEmpty ? path : "\(version) (\(path))"
    }
}

// MARK: - After download

private struct AfterDownloadOptions: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("When a download finishes") {
                Toggle("Show a notification", isOn: $settings.data.notifyOnComplete)
                Toggle("Play a sound", isOn: $settings.data.playSoundOnComplete)
                Toggle("Open the folder in Finder", isOn: $settings.data.openFolderOnComplete)
            }
            Section {
                Toggle("Run a command on the downloaded file (e.g. a virus scanner)", isOn: $settings.data.runCommandAfterDownload)
                TextField("Command", text: $settings.data.commandAfterDownload, prompt: Text(verbatim: "/opt/homebrew/bin/clamscan"))
                    .font(.system(.body, design: .monospaced))
                    .disabled(!settings.data.runCommandAfterDownload)
            } footer: {
                Text("The full path of the file is added at the end of the command.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
