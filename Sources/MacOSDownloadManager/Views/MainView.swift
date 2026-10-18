import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case all
    case category(String)
    case unfinished
    case finished
    case queue(UUID)
}

struct MainView: View {
    @EnvironmentObject var manager: DownloadManager
    @EnvironmentObject var settings: SettingsStore
    @State private var sidebar: SidebarItem? = .all
    @State private var selection = Set<UUID>()
    @State private var search = ""
    @State private var dropTargeted = false

    private var filtered: [DownloadItem] {
        var list = manager.items
        switch sidebar ?? .all {
        case .all: break
        case .category(let name): list = list.filter { $0.category == name }
        case .unfinished: list = list.filter { $0.status != .completed }
        case .finished: list = list.filter { $0.status == .completed }
        case .queue(let id): list = list.filter { $0.queueID == id }
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.fileName.lowercased().contains(query)
                    || $0.url.absoluteString.lowercased().contains(query)
                    || $0.note.lowercased().contains(query)
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            MainToolbar(selection: $selection, sidebar: sidebar, search: $search)
            Divider()
            HSplitView {
                SidebarView(selection: $sidebar)
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 300)
                DownloadTableView(items: filtered, selection: $selection)
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            StatusBarView()
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        .overlay(dropOverlay)
        .onDrop(of: [UTType.url, UTType.plainText], isTargeted: $dropTargeted) { providers in
            DropHandler.handle(providers)
            return true
        }
    }

    @ViewBuilder private var dropOverlay: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                .background(Color.accentColor.opacity(0.06))
                .overlay(
                    Label("Drop links here to download", systemImage: "arrow.down.doc")
                        .font(.title3.weight(.semibold))
                        .padding(14)
                        .background(.regularMaterial, in: Capsule())
                )
                .padding(8)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Toolbar

struct ToolButton: View {
    let title: LocalizedStringKey
    let icon: String
    let color: Color
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(disabled ? Color.secondary : color)
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(disabled ? .secondary : .primary)
                    .lineLimit(1)
            }
            .frame(minWidth: 64)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hover && !disabled ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
    }
}

struct MainToolbar: View {
    @EnvironmentObject var manager: DownloadManager
    @Binding var selection: Set<UUID>
    let sidebar: SidebarItem?
    @Binding var search: String

    private var selectedItems: [DownloadItem] {
        manager.items.filter { selection.contains($0.id) }
    }

    private var canResume: Bool {
        selectedItems.contains { $0.status != .completed && !manager.isRunning($0.id) }
    }

    private var canStop: Bool {
        selectedItems.contains { manager.isRunning($0.id) }
    }

    private var currentQueue: UUID {
        if case .queue(let id) = sidebar { return id }
        return manager.mainQueue.id
    }

    var body: some View {
        HStack(spacing: 2) {
            ToolButton(title: "Add URL", icon: "plus.circle.fill", color: .blue) {
                WindowManager.shared.showAddURL()
            }
            ToolButton(title: "Resume", icon: "play.circle.fill", color: .green, disabled: !canResume) {
                for item in selectedItems { manager.start(item.id) }
            }
            ToolButton(title: "Stop", icon: "pause.circle.fill", color: .orange, disabled: !canStop) {
                for item in selectedItems { manager.pause(item.id) }
            }
            ToolButton(title: "Stop All", icon: "stop.circle.fill", color: .red, disabled: manager.activeCount == 0) {
                manager.pauseAll()
            }
            ToolButton(title: "Delete", icon: "trash.circle.fill", color: .red, disabled: selection.isEmpty) {
                DeleteConfirmation.ask(ids: selection) { selection.removeAll() }
            }
            ToolButton(title: "Delete Completed", icon: "checkmark.circle.fill", color: .teal) {
                manager.deleteCompleted()
            }
            Divider().frame(height: 36).padding(.horizontal, 4)
            ToolButton(title: "Options", icon: "gearshape.fill", color: .gray) {
                WindowManager.shared.showOptions()
            }
            ToolButton(title: "Scheduler", icon: "calendar.badge.clock", color: .purple) {
                WindowManager.shared.showScheduler(select: currentQueue)
            }
            ToolButton(title: "Start Queue", icon: "play.square.stack.fill", color: .green) {
                manager.startQueue(currentQueue)
            }
            ToolButton(title: "Stop Queue", icon: "stop.fill", color: .red,
                       disabled: !manager.runningQueues.contains(currentQueue)) {
                manager.stopQueue(currentQueue)
            }
            Divider().frame(height: 36).padding(.horizontal, 4)
            ToolButton(title: "Grabber", icon: "globe", color: .cyan) {
                WindowManager.shared.showGrabber()
            }
            ToolButton(title: "Batch", icon: "square.stack.3d.down.right.fill", color: .indigo) {
                WindowManager.shared.showBatch()
            }
            Spacer(minLength: 12)
            SearchField(text: $search)
                .frame(width: 200)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search downloads", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.15)))
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var manager: DownloadManager
    @EnvironmentObject var settings: SettingsStore
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection.distinct()) {
            Section("Categories") {
                row("All Downloads", icon: "tray.full", count: manager.items.count)
                    .tag(SidebarItem.all)
                ForEach(settings.data.categories) { category in
                    row(LocalizedStringKey(category.name), icon: category.icon,
                        count: manager.items.filter { $0.category == category.name }.count)
                        .tag(SidebarItem.category(category.name))
                }
            }
            Section("Status") {
                row("Unfinished", icon: "arrow.down.circle",
                    count: manager.items.filter { $0.status != .completed }.count)
                    .tag(SidebarItem.unfinished)
                row("Finished", icon: "checkmark.circle",
                    count: manager.items.filter { $0.status == .completed }.count)
                    .tag(SidebarItem.finished)
            }
            Section("Queues") {
                ForEach(manager.queues) { queue in
                    queueRow(queue)
                        .tag(SidebarItem.queue(queue.id))
                        .contextMenu {
                            Button("Start Queue") { manager.startQueue(queue.id) }
                            Button("Stop Queue") { manager.stopQueue(queue.id) }
                            Button("Edit Queue…") { WindowManager.shared.showScheduler(select: queue.id) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: LocalizedStringKey, icon: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func queueRow(_ queue: DownloadQueue) -> some View {
        let running = manager.runningQueues.contains(queue.id)
        let count = manager.items.filter { $0.queueID == queue.id }.count
        return HStack {
            Label {
                Text(verbatim: queue.displayName)
            } icon: {
                Image(systemName: running ? "play.circle.fill" : "list.bullet.rectangle")
                    .foregroundStyle(running ? Color.green : Color.secondary)
            }
            Spacer()
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    @EnvironmentObject var manager: DownloadManager
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        HStack(spacing: 14) {
            Label {
                Text(verbatim: "\(manager.activeCount)")
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
            .help(Text("Active downloads"))
            Label {
                Text(verbatim: manager.totalSpeed > 0 ? Fmt.speed(manager.totalSpeed) : "0 KB/s")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "speedometer")
            }
            .help(Text("Total transfer rate"))
            Toggle(isOn: $settings.data.speedLimitEnabled) {
                Text("Speed limiter")
            }
            .toggleStyle(.checkbox)
            if settings.data.speedLimitEnabled {
                Text(verbatim: Fmt.speed(Double(settings.data.speedLimitKBps) * 1024))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(settings.data.browserIntegration ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(settings.data.browserIntegration ? "Browser integration on" : "Browser integration off")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - Drag & drop

enum DropHandler {
    private final class Collector {
        private let lock = NSLock()
        private var urls: [URL] = []

        func add(_ new: [URL]) {
            lock.lock()
            urls.append(contentsOf: new)
            lock.unlock()
        }

        var all: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    static func handle(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let collector = Collector()
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, !url.isFileURL { collector.add([url]) }
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                group.enter()
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    if let text { collector.add(extractURLs(text)) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            var seen = Set<String>()
            let unique = collector.all.filter { seen.insert($0.absoluteString).inserted }
            if unique.count == 1 {
                DownloadManager.shared.handleCapture(CaptureRequest(url: unique[0]), forceDialog: true)
            } else if unique.count > 1 {
                WindowManager.shared.showLinks(unique.map { CaptureRequest(url: $0) })
            }
        }
    }

    static func extractURLs(_ text: String) -> [URL] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .compactMap { URL(string: $0) }
            .filter { ["http", "https", "ftp"].contains($0.scheme?.lowercased() ?? "") }
    }
}

// MARK: - Delete confirmation

enum DeleteConfirmation {
    static func ask(ids: Set<UUID>, completion: @escaping () -> Void) {
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete the selected downloads?")
        alert.informativeText = String(localized: "Unfinished data will be removed. You can also move completed files to the Trash.")
        alert.addButton(withTitle: String(localized: "Delete from List"))
        alert.addButton(withTitle: String(localized: "Delete and Move Files to Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            DownloadManager.shared.delete(ids, deleteFiles: false)
            completion()
        case .alertSecondButtonReturn:
            DownloadManager.shared.delete(ids, deleteFiles: true)
            completion()
        default:
            break
        }
    }
}

extension Binding where Value: Equatable {
    /// A binding that ignores writes of the value it already holds.
    func distinct() -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { newValue in
            if newValue != wrappedValue { wrappedValue = newValue }
        })
    }
}
