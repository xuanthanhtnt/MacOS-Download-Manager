import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum FileIcon {
    private static var cache: [String: NSImage] = [:]

    static func icon(forExtension ext: String) -> NSImage {
        let key = ext.lowercased()
        if let cached = cache[key] { return cached }
        let type = UTType(filenameExtension: key) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}

struct DownloadTableView: View {
    @EnvironmentObject var manager: DownloadManager
    let items: [DownloadItem]
    @Binding var selection: Set<UUID>
    @State private var sortOrder: [KeyPathComparator<DownloadItem>] = [
        KeyPathComparator(\DownloadItem.dateAdded, order: .reverse)
    ]

    private var sorted: [DownloadItem] {
        items.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sorted, selection: $selection.distinct(), sortOrder: $sortOrder.distinct()) {
            TableColumn("File Name", value: \.fileName) { item in
                FileNameCell(item: item)
            }
            .width(min: 180, ideal: 320)

            TableColumn("Size", value: \.totalBytes) { item in
                SizeCell(item: item)
            }
            .width(min: 64, ideal: 86)

            TableColumn("Status", value: \.statusSortKey) { item in
                StatusCell(item: item)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Time Left") { item in
                TimeLeftCell(item: item)
            }
            .width(min: 56, ideal: 72)

            TableColumn("Transfer Rate") { item in
                RateCell(item: item)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Last Try", value: \.lastTryDate) { item in
                Text(verbatim: Fmt.date(item.lastTry ?? item.dateAdded))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Description", value: \.note) { item in
                Text(verbatim: item.note)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 120)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            DownloadContextMenu(ids: ids)
        } primaryAction: { ids in
            DownloadActions.openOrShow(ids)
        }
    }
}

private struct FileNameCell: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIcon.icon(forExtension: item.fileExtension))
                .resizable()
                .frame(width: 16, height: 16)
            Text(verbatim: item.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            if item.kind == .hls {
                Text(verbatim: "HLS")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.purple.opacity(0.18)))
            }
        }
    }
}

private struct SizeCell: View {
    let item: DownloadItem

    var body: some View {
        Text(verbatim: item.totalBytes > 0 ? Fmt.bytes(item.totalBytes) : "")
            .monospacedDigit()
    }
}

private struct StatusCell: View {
    let item: DownloadItem

    private var color: Color {
        switch item.status {
        case .completed: return .green
        case .failed: return .red
        case .paused, .queued: return .orange
        default: return .accentColor
        }
    }

    private var text: String {
        switch item.status {
        case .downloading:
            return item.totalBytes > 0 || item.kind == .hls ? Fmt.percent(item.progress) : Fmt.bytes(item.downloadedBytes)
        case .paused where item.progress > 0:
            return String(localized: "Paused") + " " + Fmt.percent(item.progress)
        default:
            return item.status.title
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if item.status != .completed && item.status != .queued {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(color)
                    .frame(width: 46)
            }
            Text(verbatim: text)
                .foregroundStyle(item.status == .failed ? Color.red : Color.primary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .help(item.errorMessage ?? "")
    }
}

private struct TimeLeftCell: View {
    @EnvironmentObject var manager: DownloadManager
    let item: DownloadItem

    var body: some View {
        Text(verbatim: Fmt.duration(manager.stats[item.id]?.eta(for: item)))
            .monospacedDigit()
    }
}

private struct RateCell: View {
    @EnvironmentObject var manager: DownloadManager
    let item: DownloadItem

    var body: some View {
        Text(verbatim: Fmt.speed(manager.stats[item.id]?.speed ?? 0))
            .monospacedDigit()
    }
}

// MARK: - Actions shared by the context menu and the toolbar

enum DownloadActions {
    static func openOrShow(_ ids: Set<UUID>) {
        let manager = DownloadManager.shared
        for id in ids {
            guard let item = manager.item(id) else { continue }
            if item.status == .completed {
                SystemActions.open(item.filePath)
            } else {
                WindowManager.shared.showProgress(id)
            }
        }
    }

    static func copyURLs(_ ids: Set<UUID>) {
        let urls = DownloadManager.shared.items.filter { ids.contains($0.id) }.map(\.url.absoluteString)
        ClipboardMonitor.shared.ignoreCurrentChange()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
        ClipboardMonitor.shared.ignoreCurrentChange()
    }
}

struct DownloadContextMenu: View {
    let ids: Set<UUID>

    private var manager: DownloadManager { DownloadManager.shared }
    private var items: [DownloadItem] { manager.items.filter { ids.contains($0.id) } }
    private var single: DownloadItem? { items.count == 1 ? items.first : nil }

    var body: some View {
        if !ids.isEmpty {
            if let item = single, item.status == .completed {
                Button("Open") { SystemActions.open(item.filePath) }
                Button("Show in Finder") { SystemActions.revealInFinder(item.filePath) }
                Divider()
            } else if let item = single {
                Button("Show Progress") { WindowManager.shared.showProgress(item.id) }
                Button("Open Folder") { SystemActions.revealInFinder(item.filePath) }
                Divider()
            }

            if items.contains(where: { $0.status != .completed && !manager.isRunning($0.id) }) {
                Button("Resume") { for item in items { manager.start(item.id) } }
            }
            if items.contains(where: { manager.isRunning($0.id) }) {
                Button("Stop") { for item in items { manager.pause(item.id) } }
            }
            if let item = single, !manager.isRunning(item.id) {
                Button("Redownload") { manager.redownload(item.id) }
            }
            if let item = single, item.status != .completed {
                Button("Refresh Download Address…") { WindowManager.shared.showRefreshAddress(item.id) }
            }

            Divider()
            Menu("Move to Queue") {
                ForEach(manager.queues) { queue in
                    Button(queue.displayName) { manager.move(ids, toQueue: queue.id) }
                }
                Divider()
                Button("Remove from Queue") { manager.move(ids, toQueue: nil) }
            }
            Button("Copy Address") { DownloadActions.copyURLs(ids) }

            if let item = single, item.status == .completed {
                Button("Verify Checksum…") { WindowManager.shared.showChecksum(item.id) }
            }
            if let item = single {
                Button("Properties…") { WindowManager.shared.showProperties(item.id) }
            }

            Divider()
            Button("Delete…") { DeleteConfirmation.ask(ids: ids) {} }
        }
    }
}
