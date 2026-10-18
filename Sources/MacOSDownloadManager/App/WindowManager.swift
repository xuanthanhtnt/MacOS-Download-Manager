import AppKit
import SwiftUI

/// Creates and tracks the app's AppKit windows that host SwiftUI views.
/// Windows are opened from anywhere (browser capture, clipboard, menu bar) without a SwiftUI scene.
final class WindowManager {
    static let shared = WindowManager()

    private var windows: [String: NSWindow] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]
    private var dropPanel: NSPanel?

    private init() {}

    // MARK: Generic

    func present<Content: View>(key: String,
                                title: String,
                                resizable: Bool = false,
                                floating: Bool = false,
                                autosaveName: String? = nil,
                                size: NSSize? = nil,
                                @ViewBuilder content: () -> Content) {
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = content()
            .environmentObject(DownloadManager.shared)
            .environmentObject(SettingsStore.shared)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = resizable ? [.minSize] : [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        window.styleMask = style
        window.title = title
        window.isReleasedWhenClosed = false
        window.level = floating ? .floating : .normal
        if let size { window.setContentSize(size) }
        var restored = false
        if let autosaveName {
            restored = window.setFrameUsingName(autosaveName)
            window.setFrameAutosaveName(autosaveName)
        }
        if !restored { window.center() }
        windows[key] = window
        closeObservers[key] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                     object: window, queue: .main) { [weak self] _ in
            self?.forget(key)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func forget(_ key: String) {
        windows.removeValue(forKey: key)
        if let observer = closeObservers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func close(_ key: String) {
        windows[key]?.close()
    }

    func isOpen(_ key: String) -> Bool {
        windows[key] != nil
    }

    // MARK: Windows

    func showMain() {
        present(key: "main", title: "MacOS Download Manager", resizable: true, autosaveName: "MDM.MainWindow",
                size: NSSize(width: 1080, height: 620)) {
            MainView()
        }
    }

    func showAddURL(prefill: String? = nil, videoPage: Bool = false) {
        var text = prefill ?? ""
        if text.isEmpty, let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: clip), let scheme = url.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme) {
            text = clip
        }
        present(key: "addurl", title: String(localized: "Add URL"), floating: true) {
            AddURLView(initialText: text, videoPage: videoPage)
        }
    }

    func showFileInfo(_ request: CaptureRequest) {
        present(key: "fileinfo-\(request.id.uuidString)", title: String(localized: "Download File Info"), floating: true) {
            FileInfoView(request: request)
        }
    }

    func closeFileInfo(_ request: CaptureRequest) {
        close("fileinfo-\(request.id.uuidString)")
    }

    func showProgress(_ id: UUID) {
        let name = DownloadManager.shared.item(id)?.fileName ?? "MacOS Download Manager"
        present(key: "progress-\(id.uuidString)", title: name) {
            ProgressWindowView(id: id)
        }
    }

    func showOptions(tab: OptionsTab = .general) {
        if let window = windows["options"] {
            NotificationCenter.default.post(name: .turboSelectOptionsTab, object: tab)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        present(key: "options", title: String(localized: "MacOS Download Manager Options")) {
            OptionsView(initialTab: tab)
        }
    }

    func showScheduler(select queueID: UUID? = nil) {
        present(key: "scheduler", title: String(localized: "Scheduler"), resizable: true,
                autosaveName: "MDM.Scheduler", size: NSSize(width: 820, height: 560)) {
            SchedulerView(initialSelection: queueID)
        }
    }

    func showBatch() {
        present(key: "batch", title: String(localized: "Batch Download")) {
            BatchDownloadView()
        }
    }

    func showGrabber() {
        present(key: "grabber", title: String(localized: "Site Grabber"), resizable: true,
                size: NSSize(width: 760, height: 600)) {
            SiteGrabberView()
        }
    }

    func showLinks(_ requests: [CaptureRequest]) {
        let key = "links-\(UUID().uuidString)"
        present(key: key, title: String(localized: "Select Files to Download"), resizable: true, floating: true,
                size: NSSize(width: 760, height: 520)) {
            LinkListView(requests: requests, windowKey: key)
        }
    }

    func showChecksum(_ id: UUID) {
        present(key: "checksum-\(id.uuidString)", title: String(localized: "Verify Checksum")) {
            ChecksumView(id: id)
        }
    }

    func showProperties(_ id: UUID) {
        present(key: "properties-\(id.uuidString)", title: String(localized: "Properties")) {
            PropertiesView(id: id)
        }
    }

    func showRefreshAddress(_ id: UUID) {
        present(key: "refresh-\(id.uuidString)", title: String(localized: "Refresh Download Address")) {
            RefreshAddressView(id: id)
        }
    }

    func showMediaInfo(_ url: URL) {
        let key = "media-\(UUID().uuidString)"
        present(key: key, title: String(localized: "Download Video"), floating: true) {
            MediaInfoView(pageURL: url, windowKey: key)
        }
    }

    func showAbout() {
        present(key: "about", title: String(localized: "About MacOS Download Manager")) {
            AboutView()
        }
    }

    func showCountdown(_ action: AfterQueueAction) {
        present(key: "countdown", title: "MacOS Download Manager", floating: true) {
            CountdownView(action: action)
        }
    }

    // MARK: Drop target

    func setDropTargetVisible(_ visible: Bool) {
        if visible {
            if dropPanel == nil {
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 84, height: 84),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                panel.level = .floating
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.isMovableByWindowBackground = true
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let host = NSHostingView(rootView: DropTargetView()
                    .environmentObject(DownloadManager.shared)
                    .environmentObject(SettingsStore.shared))
                host.frame = NSRect(x: 0, y: 0, width: 84, height: 84)
                panel.contentView = host
                if !panel.setFrameUsingName("MDM.DropTarget"), let screen = NSScreen.main {
                    let f = screen.visibleFrame
                    panel.setFrameOrigin(NSPoint(x: f.maxX - 120, y: f.maxY - 160))
                }
                panel.setFrameAutosaveName("MDM.DropTarget")
                dropPanel = panel
            }
            dropPanel?.orderFrontRegardless()
        } else {
            dropPanel?.orderOut(nil)
        }
    }
}

extension Notification.Name {
    static let turboSelectOptionsTab = Notification.Name("MDM.selectOptionsTab")
}
