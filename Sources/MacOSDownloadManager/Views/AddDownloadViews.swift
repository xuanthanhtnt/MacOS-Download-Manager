import SwiftUI
import AppKit

// MARK: - Add URL

struct AddURLView: View {
    @State private var text: String
    @State private var useAuth = false
    @State private var user = ""
    @State private var password = ""

    init(initialText: String) {
        _text = State(initialValue: initialText)
    }

    private var urls: [URL] {
        DropHandler.extractURLs(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enter the address of the file to download")
                        .font(.headline)
                    Text("You can paste several addresses, one per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            Toggle("Use authorization", isOn: $useAuth)
            if useAuth {
                HStack {
                    TextField("Login", text: $user)
                    SecureField("Password", text: $password)
                }
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { WindowManager.shared.close("addurl") }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urls.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func submit() {
        let list = urls
        guard !list.isEmpty else { return }
        WindowManager.shared.close("addurl")
        let requests = list.map { url -> CaptureRequest in
            var r = CaptureRequest(url: url)
            if useAuth && !user.isEmpty {
                r.username = user
                r.password = password
            }
            return r
        }
        if requests.count == 1 {
            DownloadManager.shared.handleCapture(requests[0], forceDialog: true)
        } else {
            WindowManager.shared.showLinks(requests)
        }
    }
}

// MARK: - Download File Info

struct FileInfoView: View {
    let request: CaptureRequest
    @EnvironmentObject var manager: DownloadManager
    @EnvironmentObject var settings: SettingsStore

    @State private var urlText = ""
    @State private var fileName = ""
    @State private var folder = ""
    @State private var category = "General"
    @State private var note = ""
    @State private var nameEdited = false
    @State private var folderEdited = false
    @State private var probing = true
    @State private var size: Int64 = -1
    @State private var resumable: Bool?
    @State private var isHLS = false
    @State private var variants: [HLSVariant] = []
    @State private var variantURL: URL?
    @State private var duration: Double = 0
    @State private var probeError: String?
    @State private var initialized = false
    @State private var probeTask: Task<Void, Never>?

    private var targetURL: URL? {
        URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: FileIcon.icon(forExtension: (fileName as NSString).pathExtension))
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: fileName.isEmpty ? "…" : fileName)
                        .font(.headline)
                        .lineLimit(2)
                    infoLine
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("URL").gridColumnAlignment(.trailing)
                    TextField("URL", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { runProbe() }
                }
                GridRow {
                    Text("Category")
                    Picker("", selection: $category) {
                        ForEach(settings.data.categories) { c in
                            Label(c.displayName, systemImage: c.icon).tag(c.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    .onChange(of: category) { newValue in
                        if !folderEdited { folder = settings.folder(forCategory: newValue) }
                    }
                }
                GridRow {
                    Text("Save As")
                    HStack {
                        TextField("File name", text: Binding(get: { fileName }, set: { fileName = $0; nameEdited = true }))
                            .textFieldStyle(.roundedBorder)
                    }
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
                if isHLS && !variants.isEmpty {
                    GridRow {
                        Text("Quality")
                        Picker("", selection: $variantURL) {
                            ForEach(variants) { v in
                                Text(verbatim: v.title).tag(Optional(v.url))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                    }
                }
                GridRow {
                    Text("Description")
                    TextField("Optional", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let existing = targetURL.flatMap({ manager.existingItem(for: $0) }) {
                Label {
                    Text("This address is already in the download list: ") + Text(verbatim: existing.fileName)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
            }

            HStack {
                Menu("Download Later") {
                    ForEach(manager.queues) { queue in
                        Button(queue.displayName) { add(start: false, queue: queue.id) }
                    }
                    Divider()
                    Button("Add without a queue") { add(start: false, queue: nil) }
                }
                .fixedSize()
                .disabled(targetURL == nil || fileName.isEmpty)
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Download") { add(start: true, queue: nil) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(targetURL == nil || fileName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear(perform: setup)
        .onDisappear { probeTask?.cancel() }
    }

    @ViewBuilder private var infoLine: some View {
        HStack(spacing: 10) {
            if probing {
                ProgressView().controlSize(.small)
                Text("Getting file information…").foregroundStyle(.secondary)
            } else if let probeError {
                Label {
                    Text(verbatim: probeError)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .foregroundStyle(.secondary)
            } else {
                if isHLS {
                    Text("HLS video stream").foregroundStyle(.purple)
                    if duration > 0 {
                        Text(verbatim: Fmt.duration(duration)).foregroundStyle(.secondary)
                    }
                } else {
                    Text(verbatim: size > 0 ? Fmt.bytes(size) : String(localized: "Unknown size"))
                        .foregroundStyle(.secondary)
                }
                if let resumable {
                    Label(resumable ? "Resume supported" : "Resume not supported",
                          systemImage: resumable ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(resumable ? Color.green : Color.orange)
                }
            }
        }
        .font(.caption)
    }

    private func setup() {
        guard !initialized else { return }
        initialized = true
        urlText = request.url.absoluteString
        if let name = request.suggestedName, !name.isEmpty {
            fileName = name
            nameEdited = true
        } else {
            fileName = FileNameUtils.ensureExtension(FileNameUtils.nameFromURL(request.url), mime: request.mime)
        }
        if let s = request.fileSize { size = s }
        category = settings.categoryName(forFileName: fileName)
        folder = settings.folder(forCategory: category)
        runProbe()
    }

    private func runProbe() {
        guard let url = targetURL else { return }
        probeTask?.cancel()
        probing = true
        probeError = nil
        var headers: [String: String] = ["User-Agent": request.userAgent ?? settings.data.userAgent]
        if let r = request.referer, !r.isEmpty { headers["Referer"] = r }
        if let c = request.cookies, !c.isEmpty { headers["Cookie"] = c }
        var user = request.username
        var pass = request.password
        if user == nil, let login = settings.siteLogin(for: url) {
            user = login.username
            pass = Keychain.get(account: "site-\(login.id.uuidString)")
        }
        let proxy = settings.proxyDictionary
        let timeout = TimeInterval(max(5, settings.data.timeoutSeconds))
        let u = user, p = pass
        probeTask = Task {
            do {
                let result = try await URLProbe.probe(url: url, headers: headers, username: u, password: p,
                                                      proxy: proxy, timeout: timeout)
                if Task.isCancelled { return }
                apply(result)
            } catch {
                if Task.isCancelled { return }
                probing = false
                probeError = error.localizedDescription
            }
        }
    }

    private func apply(_ result: ProbeResult) {
        probing = false
        size = result.totalBytes
        resumable = result.resumable
        isHLS = result.isHLS
        variants = result.hlsVariants
        duration = result.hlsDuration
        if isHLS {
            let preferred = M3U8Variants.best(result.hlsVariants)
            variantURL = preferred?.url
        }
        if !nameEdited, let name = result.fileName, !name.isEmpty {
            fileName = name
            let newCategory = settings.categoryName(forFileName: name)
            if newCategory != category {
                category = newCategory
                if !folderEdited { folder = settings.folder(forCategory: newCategory) }
            }
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
        guard let url = targetURL else { return }
        var item = DownloadItem(url: url, fileName: fileName, directory: folder)
        item.category = category
        item.note = note
        item.referer = request.referer
        item.cookies = request.cookies
        item.userAgent = request.userAgent
        item.username = request.username
        item.totalBytes = size
        item.resumable = resumable ?? true
        item.autoName = !nameEdited && probeError != nil
        item.queueID = queue
        if isHLS {
            item.kind = .hls
            item.hlsVariantURL = variantURL
            item.totalBytes = -1
        }
        manager.add(item, password: request.password, start: start)
        close()
    }

    private func close() {
        probeTask?.cancel()
        WindowManager.shared.closeFileInfo(request)
    }
}

enum M3U8Variants {
    static func best(_ variants: [HLSVariant]) -> HLSVariant? {
        var playlist = HLSPlaylist()
        playlist.variants = variants
        return playlist.bestVariant
    }
}
