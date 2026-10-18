import SwiftUI
import AppKit

/// The per-download dialog: live status while downloading, "Download complete" when finished.
struct ProgressWindowView: View {
    let id: UUID
    @EnvironmentObject var manager: DownloadManager

    var body: some View {
        Group {
            if let item = manager.item(id) {
                if item.status == .completed {
                    CompletedView(item: item)
                } else {
                    DownloadProgressView(item: item, stats: manager.stats[id])
                }
            } else {
                VStack(spacing: 12) {
                    Text("This download was removed from the list.")
                    Button("Close") { WindowManager.shared.close("progress-\(id.uuidString)") }
                }
                .padding(30)
            }
        }
    }
}

private struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(verbatim: value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DownloadProgressView: View {
    let item: DownloadItem
    let stats: RuntimeStats?
    @EnvironmentObject var manager: DownloadManager
    @AppStorage("MDM.progress.showDetails") private var showDetails = true

    private var running: Bool { manager.isRunning(item.id) }

    private var statusText: String {
        if let error = item.errorMessage, item.status == .failed { return error }
        switch item.status {
        case .downloading: return String(localized: "Receiving data…")
        default: return item.status.title
        }
    }

    private var downloadedText: String {
        if item.kind == .hls && item.hlsSegmentCount > 0 {
            return "\(Fmt.bytes(item.downloadedBytes))  (\(item.hlsDoneSegments.count)/\(item.hlsSegmentCount) · \(Fmt.percent(item.progress)))"
        }
        if item.totalBytes > 0 {
            return "\(Fmt.bytes(item.downloadedBytes))  (\(Fmt.percent(item.progress)))"
        }
        return Fmt.bytes(item.downloadedBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                InfoRow(label: "URL", value: item.url.absoluteString)
                InfoRow(label: "Status", value: statusText)
                InfoRow(label: "File size", value: item.totalBytes > 0 ? Fmt.bytes(item.totalBytes) : String(localized: "Unknown"))
                InfoRow(label: "Downloaded", value: downloadedText)
                InfoRow(label: "Transfer rate", value: Fmt.speed(stats?.speed ?? 0))
                InfoRow(label: "Time left", value: Fmt.duration(stats?.eta(for: item)))
                InfoRow(label: "Resume capability",
                        value: item.resumable ? String(localized: "Yes") : String(localized: "No"))
            }
            .font(.system(size: 12))

            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .tint(item.status == .failed ? .red : .accentColor)

            HStack {
                Button {
                    showDetails.toggle()
                } label: {
                    Label(showDetails ? "Hide details" : "Show details",
                          systemImage: showDetails ? "chevron.up" : "chevron.down")
                }
                Spacer()
                if running {
                    Button("Pause") { manager.pause(item.id) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Resume") { manager.start(item.id) }
                        .keyboardShortcut(.defaultAction)
                }
                Button("Cancel") {
                    manager.pause(item.id)
                    WindowManager.shared.close("progress-\(item.id.uuidString)")
                }
                .keyboardShortcut(.cancelAction)
            }

            if showDetails {
                Divider()
                if item.kind == .media {
                    MediaPartsView(item: item)
                } else if item.kind == .hls {
                    HLSPartsBar(item: item)
                        .frame(height: 14)
                    Text(verbatim: String(format: NSLocalizedString("%d of %d parts downloaded", comment: ""),
                                          item.hlsDoneSegments.count, item.hlsSegmentCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    SegmentBar(item: item, active: Set(stats?.activeSegments ?? []))
                        .frame(height: 14)
                    ConnectionsTable(item: item, active: Set(stats?.activeSegments ?? []))
                        .frame(height: 170)
                }
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}

/// IDM-style bar: one block per connection, filled up to what that connection downloaded.
struct SegmentBar: View {
    let item: DownloadItem
    let active: Set<Int>

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.primary.opacity(0.08)))
            guard item.totalBytes > 0 else { return }
            let total = Double(item.totalBytes)
            for segment in item.segments {
                let x = Double(segment.start) / total * size.width
                let w = Double(segment.downloaded) / total * size.width
                guard w > 0 else { continue }
                let color: Color = segment.isComplete ? .green : (active.contains(segment.id) ? .blue : .orange)
                context.fill(Path(CGRect(x: x, y: 0, width: max(1, w), height: size.height)), with: .color(color.opacity(0.85)))
                if segment.end >= 0 && !segment.isComplete {
                    let endX = Double(segment.end + 1) / total * size.width
                    context.fill(Path(CGRect(x: endX - 1, y: 0, width: 1, height: size.height)),
                                 with: .color(Color.primary.opacity(0.35)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct HLSPartsBar: View {
    let item: DownloadItem

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.primary.opacity(0.08)))
            guard item.hlsSegmentCount > 0 else { return }
            let w = size.width / Double(item.hlsSegmentCount)
            for index in item.hlsDoneSegments {
                context.fill(Path(CGRect(x: Double(index) * w, y: 0, width: max(1, w), height: size.height)),
                             with: .color(Color.purple.opacity(0.8)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct ConnectionsTable: View {
    let item: DownloadItem
    let active: Set<Int>

    private struct Row: Identifiable {
        let id: Int
        let number: Int
        let downloaded: String
        let info: String
    }

    private var rows: [Row] {
        item.segments.enumerated().map { n, seg in
            let info: String
            if seg.isComplete {
                info = String(localized: "Complete")
            } else if active.contains(seg.id) {
                info = String(localized: "Receiving data…")
            } else {
                info = String(localized: "Waiting")
            }
            let range = seg.end >= 0 ? "\(Fmt.bytes(seg.downloaded)) / \(Fmt.bytes(seg.length))" : Fmt.bytes(seg.downloaded)
            return Row(id: seg.id, number: n + 1, downloaded: range, info: info)
        }
    }

    var body: some View {
        Table(rows) {
            TableColumn("N.") { row in Text(verbatim: "\(row.number)").monospacedDigit() }
                .width(36)
            TableColumn("Downloaded") { row in Text(verbatim: row.downloaded).monospacedDigit() }
            TableColumn("Info") { row in Text(verbatim: row.info) }
        }
    }
}

struct CompletedView: View {
    let item: DownloadItem
    @EnvironmentObject var settings: SettingsStore

    private func closeWindow() {
        WindowManager.shared.close("progress-\(item.id.uuidString)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: FileIcon.icon(forExtension: item.fileExtension))
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Download complete", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text(verbatim: item.fileName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                InfoRow(label: "Address", value: item.url.absoluteString)
                InfoRow(label: "File size", value: Fmt.bytes(item.totalBytes))
                InfoRow(label: "Saved as", value: item.filePath)
            }
            .font(.system(size: 12))
            Toggle("Don't show this dialog again", isOn: Binding(
                get: { !settings.data.showCompleteDialog },
                set: { settings.data.showCompleteDialog = !$0 }))
                .font(.caption)
            HStack {
                Spacer()
                Button("Open Folder") {
                    SystemActions.revealInFinder(item.filePath)
                    closeWindow()
                }
                Button("Close") { closeWindow() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") {
                    SystemActions.open(item.filePath)
                    closeWindow()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Video and audio streams of a video-page download.
private struct MediaPartsView: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if item.mediaParts.isEmpty {
                Text("Reading the video page…").foregroundStyle(.secondary).font(.caption)
            }
            ForEach(Array(item.mediaParts.enumerated()), id: \.offset) { index, part in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: index == 0 && item.mediaParts.count > 1 ? "film" : (item.mediaParts.count > 1 ? "waveform" : "doc"))
                            .foregroundStyle(.secondary)
                        Text(verbatim: label(index))
                        Spacer()
                        Text(verbatim: part.done
                             ? String(localized: "Complete")
                             : "\(Fmt.bytes(part.downloadedBytes)) / \(part.totalBytes > 0 ? Fmt.bytes(part.totalBytes) : "?")")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    ProgressView(value: progress(part))
                        .tint(part.done ? .green : .accentColor)
                }
            }
            if item.status == .assembling {
                Label("Joining video and audio…", systemImage: "square.stack.3d.down.forward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ index: Int) -> String {
        guard item.mediaParts.count > 1 else { return String(localized: "Stream") }
        return index == 0 ? String(localized: "Video stream") : String(localized: "Audio stream")
    }

    private func progress(_ part: MediaPartState) -> Double {
        if part.done { return 1 }
        guard part.totalBytes > 0 else { return 0 }
        return min(1, Double(part.downloadedBytes) / Double(part.totalBytes))
    }
}
