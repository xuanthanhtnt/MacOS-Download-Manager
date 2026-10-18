import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct MacOSDownloadManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var manager = DownloadManager.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { settings.data.showMenuBarIcon },
                                         set: { settings.data.showMenuBarIcon = $0 })) {
            MenuBarView()
                .environmentObject(manager)
                .environmentObject(settings)
        } label: {
            Image(systemName: manager.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .menuBarExtraStyle(.window)
        .commands {
            AppCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self,
                                                     andSelector: #selector(handleGetURL(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DownloadManager.shared.bootstrap()
        WindowManager.shared.showMain()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.showMain() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        DownloadManager.shared.prepareForTermination()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { URLSchemeHandler.handle(url) }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        URLSchemeHandler.handle(url)
    }
}

/// Handles `macosdm://add?url=…` links (bookmarklets, Safari, scripts) and opened .ef2/.txt lists.
enum URLSchemeHandler {
    static func handle(_ url: URL) {
        DownloadManager.shared.bootstrap()
        if url.isFileURL {
            DownloadManager.shared.importList(from: url)
            return
        }
        guard url.scheme?.lowercased() == "macosdm" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        guard let target = value("url").flatMap(URL.init(string:)), target.scheme != nil else {
            WindowManager.shared.showMain()
            return
        }
        var request = CaptureRequest(url: target)
        request.referer = value("referrer") ?? value("referer")
        request.suggestedName = value("name")
        DownloadManager.shared.handleCapture(request, forceDialog: true)
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Options…") { WindowManager.shared.showOptions() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add URL…") { WindowManager.shared.showAddURL() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Add Batch Download…") { WindowManager.shared.showBatch() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Site Grabber…") { WindowManager.shared.showGrabber() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Import Download List…") { ImportExport.importList() }
            Menu("Export Download List") {
                Button("As Text File (.txt)…") { ImportExport.exportList(ef2: false) }
                Button("As IDM List (.ef2)…") { ImportExport.exportList(ef2: true) }
            }
        }
        CommandMenu("Downloads") {
            Button("Show Download List") { WindowManager.shared.showMain() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Resume All") { DownloadManager.shared.resumeAll() }
            Button("Stop All") { DownloadManager.shared.pauseAll() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Delete All Completed") { DownloadManager.shared.deleteCompleted() }
            Divider()
            Button("Start Main Queue") { DownloadManager.shared.startQueue(DownloadManager.shared.mainQueue.id) }
            Button("Stop Main Queue") { DownloadManager.shared.stopQueue(DownloadManager.shared.mainQueue.id) }
            Button("Scheduler…") { WindowManager.shared.showScheduler() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            SpeedLimiterToggle()
            DropTargetToggle()
        }
        CommandGroup(replacing: .help) {
            Button("Install Browser Extension…") { WindowManager.shared.showOptions(tab: .browser) }
            Button("MacOS Download Manager on GitHub") {
                if let url = URL(string: "https://github.com/xuanthanhtnt/MacOS-Download-Manager") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

private struct SpeedLimiterToggle: View {
    @ObservedObject private var settings = SettingsStore.shared
    var body: some View {
        Toggle("Speed Limiter", isOn: $settings.data.speedLimitEnabled)
            .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}

private struct DropTargetToggle: View {
    @ObservedObject private var settings = SettingsStore.shared
    var body: some View {
        Toggle("Show Drop Target", isOn: $settings.data.showDropTarget)
    }
}

enum ImportExport {
    static func importList() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText, .text]
        if let ef2 = UTType(filenameExtension: "ef2") { types.append(ef2) }
        panel.allowedContentTypes = types
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            DownloadManager.shared.importList(from: url)
        }
    }

    static func exportList(ef2: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ef2 ? "MacOS-Download-Manager-downloads.ef2" : "MacOS-Download-Manager-downloads.txt"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            let manager = DownloadManager.shared
            manager.export(manager.items, to: url, ef2: ef2)
        }
    }
}
