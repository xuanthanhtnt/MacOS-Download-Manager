import SwiftUI
import AppKit

// MARK: - Batch download

struct BatchDownloadView: View {
    @EnvironmentObject var manager: DownloadManager
    @State private var template = "https://example.com/images/photo*.jpg"
    @State private var useLetters = false
    @State private var from = "1"
    @State private var to = "10"
    @State private var width = 0

    private var urls: [URL] {
        BatchExpander.expand(template: template, letters: useLetters, from: from, to: to, width: width)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a group of files whose addresses differ only by a number or a letter. Use * as the wildcard.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Address with *", text: $template)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            HStack(spacing: 16) {
                Picker("Replace * with", selection: $useLetters) {
                    Text("Numbers").tag(false)
                    Text("Letters").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                Spacer()
            }
            HStack(spacing: 12) {
                Text("From")
                TextField("", text: $from).frame(width: 70).textFieldStyle(.roundedBorder)
                Text("To")
                TextField("", text: $to).frame(width: 70).textFieldStyle(.roundedBorder)
                if !useLetters {
                    Stepper(value: $width, in: 0...8) {
                        Text("Wildcard length")
                        Text(verbatim: width == 0 ? "–" : "\(width)").monospacedDigit()
                    }
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: String(format: NSLocalizedString("%d files", comment: ""), urls.count)).fontWeight(.semibold)
                    if let first = urls.first {
                        Text(verbatim: first.absoluteString).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                    if urls.count > 2 { Text(verbatim: "…").font(.caption) }
                    if urls.count > 1, let last = urls.last {
                        Text(verbatim: last.absoluteString).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { WindowManager.shared.close("batch") }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Files…") {
                    let list = urls
                    WindowManager.shared.close("batch")
                    WindowManager.shared.showLinks(list.map { CaptureRequest(url: $0) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urls.isEmpty || !template.contains("*"))
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

// MARK: - Site grabber

struct SiteGrabberView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var startURL = ""
    @State private var depth = 1
    @State private var extensions = "jpg jpeg png gif webp pdf zip mp3 mp4"
    @State private var sameHost = true
    @State private var maxPages = 200
    @State private var running = false
    @State private var pages = 0
    @State private var found = 0
    @State private var grabber: SiteGrabber?
    @State private var task: Task<Void, Never>?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The grabber explores a web site and collects links to the files you want, like IDM's Site Grabber.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Start page", text: $startURL, prompt: Text(verbatim: "https://"))
                Stepper(value: $depth, in: 0...5) {
                    LabeledContent("Explore links up to depth") { Text(verbatim: "\(depth)").monospacedDigit() }
                }
                TextField("File types", text: $extensions)
                Toggle("Stay on the same server", isOn: $sameHost)
                Stepper(value: $maxPages, in: 10...2000, step: 10) {
                    LabeledContent("Maximum pages to explore") { Text(verbatim: "\(maxPages)").monospacedDigit() }
                }
            }
            .formStyle(.grouped)
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text(verbatim: String(format: NSLocalizedString("Pages explored: %d · Files found: %d", comment: ""), pages, found))
                        .foregroundStyle(.secondary)
                } else if let message {
                    Text(verbatim: message).foregroundStyle(.secondary)
                }
                Spacer()
                if running {
                    Button("Stop") {
                        grabber?.cancel()
                        task?.cancel()
                    }
                } else {
                    Button("Close") { WindowManager.shared.close("grabber") }
                        .keyboardShortcut(.cancelAction)
                    Button("Start") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(URL(string: startURL)?.host == nil)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
    }

    private func start() {
        guard let url = URL(string: startURL.trimmingCharacters(in: .whitespaces)), url.host != nil else { return }
        let exts = Set(extensions.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: " ,;"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". *")) }
            .filter { !$0.isEmpty })
        let options = SiteGrabber.Options(startURL: url, depth: depth, extensions: exts, sameHostOnly: sameHost,
                                          maxPages: maxPages, userAgent: settings.data.userAgent)
        let g = SiteGrabber()
        grabber = g
        running = true
        pages = 0
        found = 0
        message = nil
        task = Task {
            let result = await g.run(options) { p, f in
                DispatchQueue.main.async {
                    pages = p
                    found = f
                }
            }
            running = false
            if result.isEmpty {
                message = String(localized: "No matching files were found.")
            } else {
                message = String(format: NSLocalizedString("%d files found.", comment: ""), result.count)
                WindowManager.shared.showLinks(result.map { CaptureRequest(url: $0, referer: url.absoluteString) })
            }
        }
    }
}

// MARK: - Link selection list

struct LinkListView: View {
    let windowKey: String
    @EnvironmentObject var manager: DownloadManager
    @EnvironmentObject var settings: SettingsStore
    @State private var rows: [Row]
    @State private var filter = ""
    @State private var queueID: UUID?
    @State private var startNow = true

    struct Row: Identifiable {
        let id = UUID()
        let request: CaptureRequest
        var selected: Bool
        var name: String { FileNameUtils.nameFromURL(request.url) }
        var ext: String { request.url.pathExtension.lowercased() }
    }

    init(requests: [CaptureRequest], windowKey: String) {
        self.windowKey = windowKey
        let capture = SettingsStore.shared.data.captureExtensions
        let anyMatching = requests.contains { capture.contains($0.url.pathExtension.lowercased()) }
        _rows = State(initialValue: requests.map { r in
            Row(request: r, selected: !anyMatching || capture.contains(r.url.pathExtension.lowercased()))
        })
    }

    private var visibleIndices: [Int] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.indices.filter { q.isEmpty || rows[$0].request.url.absoluteString.lowercased().contains(q) }
    }

    private var selectedCount: Int { rows.filter(\.selected).count }

    private var extensionsPresent: [String] {
        Array(Set(rows.map(\.ext).filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SearchField(text: $filter).frame(width: 240)
                Menu("Select Type") {
                    ForEach(extensionsPresent, id: \.self) { ext in
                        Button(ext.uppercased()) {
                            for i in rows.indices { rows[i].selected = rows[i].ext == ext }
                        }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Select All") { for i in visibleIndices { rows[i].selected = true } }
                Button("Select None") { for i in visibleIndices { rows[i].selected = false } }
            }
            List {
                ForEach(visibleIndices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $rows[index].selected).labelsHidden()
                        Image(nsImage: FileIcon.icon(forExtension: rows[index].ext))
                            .resizable()
                            .frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: rows[index].name).lineLimit(1)
                            Text(verbatim: rows[index].request.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            HStack {
                Text(verbatim: String(format: NSLocalizedString("%d of %d selected", comment: ""), selectedCount, rows.count))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Queue", selection: $queueID) {
                    Text("No queue").tag(UUID?.none)
                    ForEach(manager.queues) { q in
                        Text(verbatim: q.displayName).tag(Optional(q.id))
                    }
                }
                .frame(width: 260)
                Toggle("Start now", isOn: $startNow)
                Button("Cancel") { WindowManager.shared.close(windowKey) }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { addSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCount == 0)
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 420)
        .onAppear { if queueID == nil { queueID = manager.mainQueue.id } }
    }

    private func addSelected() {
        let chosen = rows.filter(\.selected).map(\.request)
        let queue = queueID
        WindowManager.shared.close(windowKey)
        if let queue, startNow {
            for r in chosen { manager.quickAdd(r, start: false, queueID: queue) }
            manager.startQueue(queue)
        } else {
            for r in chosen { manager.quickAdd(r, start: startNow, queueID: queue) }
        }
    }
}

// MARK: - Checksum

struct ChecksumView: View {
    let id: UUID
    @EnvironmentObject var manager: DownloadManager
    @State private var algorithm: ChecksumAlgorithm = .sha256
    @State private var result = ""
    @State private var expected = ""
    @State private var progress: Double = 0
    @State private var working = false
    @State private var error: String?

    private var matches: Bool? {
        let e = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !e.isEmpty, !result.isEmpty else { return nil }
        return e == result.lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: manager.item(id)?.fileName ?? "").font(.headline)
            Picker("Algorithm", selection: $algorithm) {
                ForEach(ChecksumAlgorithm.allCases) { a in Text(verbatim: a.rawValue).tag(a) }
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Calculate") { calculate() }
                    .disabled(working)
                if working { ProgressView(value: progress).frame(width: 200) }
            }
            TextField("Result", text: .constant(result))
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            TextField("Paste the expected checksum to compare", text: $expected)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            if let matches {
                Label(matches ? "The checksums match" : "The checksums do NOT match",
                      systemImage: matches ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundStyle(matches ? Color.green : Color.red)
            }
            if let error { Text(verbatim: error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Close") { WindowManager.shared.close("checksum-\(id.uuidString)") }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func calculate() {
        guard let path = manager.item(id)?.filePath else { return }
        working = true
        progress = 0
        result = ""
        error = nil
        let algo = algorithm
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let hash = try Checksum.compute(algo, path: path) { p in
                    DispatchQueue.main.async { progress = p }
                }
                DispatchQueue.main.async {
                    result = hash
                    working = false
                }
            } catch let failure {
                DispatchQueue.main.async {
                    error = failure.localizedDescription
                    working = false
                }
            }
        }
    }
}

// MARK: - Properties

struct PropertiesView: View {
    let id: UUID
    @EnvironmentObject var manager: DownloadManager
    @State private var fileName = ""
    @State private var urlText = ""
    @State private var referer = ""
    @State private var note = ""
    @State private var loaded = false

    var body: some View {
        let item = manager.item(id)
        VStack(alignment: .leading, spacing: 12) {
            if let item {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("File name").gridColumnAlignment(.trailing)
                        TextField("", text: $fileName).textFieldStyle(.roundedBorder)
                            .disabled(item.status == .completed || manager.isRunning(id))
                    }
                    GridRow {
                        Text("Address")
                        TextField("", text: $urlText).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Referer")
                        TextField("", text: $referer).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Description")
                        TextField("", text: $note).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Folder")
                        Text(verbatim: item.directory).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Size")
                        Text(verbatim: item.totalBytes > 0 ? Fmt.bytes(item.totalBytes) : "—").foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Status")
                        Text(verbatim: item.errorMessage ?? item.status.title).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Added")
                        Text(verbatim: Fmt.date(item.dateAdded)).foregroundStyle(.secondary)
                    }
                    if item.dateCompleted != nil {
                        GridRow {
                            Text("Completed")
                            Text(verbatim: Fmt.date(item.dateCompleted)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            guard !loaded, let item = manager.item(id) else { return }
            loaded = true
            fileName = item.fileName
            urlText = item.url.absoluteString
            referer = item.referer ?? ""
            note = item.note
        }
    }

    private func close() {
        WindowManager.shared.close("properties-\(id.uuidString)")
    }

    private func save() {
        let newURL = URL(string: urlText.trimmingCharacters(in: .whitespaces))
        let running = manager.isRunning(id)
        manager.update(id) { item in
            if item.status != .completed && !running {
                let clean = FileNameUtils.sanitize(fileName)
                if !clean.isEmpty && clean != item.fileName {
                    item.fileName = clean
                    item.autoName = false
                }
            }
            item.referer = referer.isEmpty ? nil : referer
            item.note = note
        }
        if let newURL, newURL.scheme != nil, newURL != manager.item(id)?.url {
            manager.refreshAddress(id, to: newURL)
        }
        close()
    }
}

// MARK: - Refresh download address

struct RefreshAddressView: View {
    let id: UUID
    @EnvironmentObject var manager: DownloadManager
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When a download link expires, paste a fresh link to the same file. MacOS Download Manager keeps the data already downloaded and continues from where it stopped.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            Text(verbatim: manager.item(id)?.fileName ?? "").font(.headline)
            TextField("New address", text: $text)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { WindowManager.shared.close("refresh-\(id.uuidString)") }
                    .keyboardShortcut(.cancelAction)
                Button("Update and Resume") {
                    guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return }
                    manager.refreshAddress(id, to: url)
                    manager.start(id)
                    WindowManager.shared.close("refresh-\(id.uuidString)")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(URL(string: text)?.scheme == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string), URL(string: clip)?.scheme != nil {
                text = clip
            }
        }
    }
}
