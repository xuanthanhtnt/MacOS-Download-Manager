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
    /// Set by the menu bar's Quit (and the scheduler, the self-test, log out/shut down): really quit.
    static var reallyQuit = false

    static func quitCompletely() {
        reallyQuit = true
        NSApp.terminate(nil)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Log out, restart and shut down must never be held up by the app.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification,
                                                          object: nil, queue: .main) { _ in
            AppDelegate.reallyQuit = true
        }
        NSAppleEventManager.shared().setEventHandler(self,
                                                     andSelector: #selector(handleGetURL(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DownloadManager.shared.bootstrap()
        WindowManager.shared.showMain()
        if let target = ProcessInfo.processInfo.environment["MDM_SELFTEST_YTDLP"], !target.isEmpty {
            SelfTest.runVideoTools(reportTo: target)
        }
        if let target = ProcessInfo.processInfo.environment["MDM_SELFTEST_QUIT"], !target.isEmpty {
            SelfTest.runQuitBehaviour(reportTo: target)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.showMain() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppDelegate.reallyQuit, AppDelegate.quitMeansMenuBar() else { return .terminateNow }
        WindowManager.shared.moveToMenuBar()
        return .terminateCancel
    }

    /// ⌘Q, the app menu's Quit and the Dock's Quit keep the app running in the menu bar (an option, on by
    /// default). Quit requests from the system or other apps (Finder replacing the app during an update,
    /// installers, scripts) really quit.
    static func quitMeansMenuBar() -> Bool {
        let data = SettingsStore.shared.data
        guard data.keepRunningInMenuBar, data.showMenuBarIcon else { return false }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else {
            return true // ⌘Q / app menu: no Apple event
        }
        if let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)), reason.enumCodeValue != 0 {
            return false // log out, restart, shut down
        }
        guard let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)) else { return false }
        let app = NSRunningApplication(processIdentifier: pid_t(sender.int32Value))
        return app?.bundleIdentifier == "com.apple.dock"
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
        CommandGroup(replacing: .appInfo) {
            Button("About MacOS Download Manager") { WindowManager.shared.showAbout() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Options…") { WindowManager.shared.showOptions() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add URL…") { WindowManager.shared.showAddURL() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Download Video from Web Page…") { WindowManager.shared.showAddURL(videoPage: true) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
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
            Button("Report a Bug…") { AppInfo.reportBug() }
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

/// CI check: installs the video tools and runs yt-dlp from inside the real app, the way users do,
/// then writes the result to a file and quits. Enabled only by the MDM_SELFTEST_YTDLP variable.
enum SelfTest {
    /// CI check of "Quit keeps running in the menu bar": quits like ⌘Q, reports whether the app is still
    /// running without a Dock icon, reopens the window, then waits for the test to ask it to quit from outside.
    static func runQuitBehaviour(reportTo path: String) {
        func titledWindows() -> Int { NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.count }
        func policy() -> String {
            switch NSApp.activationPolicy() {
            case .regular: return "regular"
            case .accessory: return "accessory"
            default: return "prohibited"
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            var report = "windows-before=\(titledWindows())\npolicy-before=\(policy())\n"
            NSApp.terminate(nil) // what ⌘Q does
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                report += "cmdq-still-running=yes\npolicy-after-quit=\(policy())\nwindows-after-quit=\(titledWindows())\n"
                WindowManager.shared.showMain()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    report += "policy-after-reopen=\(policy())\nwindows-after-reopen=\(titledWindows())\n"
                    try? report.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    static func runVideoTools(reportTo path: String) {
        Task.detached {
            var report = ""
            do {
                if !MediaTools.shared.isComplete {
                    try await MediaTools.shared.installMissing()
                }
                let yt = try await MediaTools.runProcess(MediaTools.shared.ytdlpPath, ["--version"], timeout: 120)
                let deno = try await MediaTools.runProcess(MediaTools.shared.denoPath, ["--version"], timeout: 60)
                report = "ytdlp-status=\(yt.status)\nytdlp=\(yt.stdout.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                    + "ytdlp-error=\(yt.stderrTail)\ndeno-status=\(deno.status)\n"
                    + "deno=\(deno.stdout.split(separator: "\n").first ?? "")\n"
                // yt-dlp unpacks its Python library into a temp folder: if files written by helper
                // programs are quarantined, macOS refuses to load that library on Macs with Gatekeeper on.
                let probe = NSTemporaryDirectory() + "mdm-quarantine-probe-\(getpid())"
                unlink(probe)
                _ = try await MediaTools.runProcess("/usr/bin/touch", [probe], timeout: 30)
                report += "child-quarantine=\(isQuarantined(probe) ? "yes" : "no")\n"
                unlink(probe)
                let gatekeeper = try? await MediaTools.runProcess("/usr/sbin/spctl", ["--status"], timeout: 30)
                report += "gatekeeper=\((gatekeeper?.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines))\n"
                // ffmpeg: downloaded by the app (joins streams macOS cannot join).
                if let ffmpeg = MediaTools.findFFmpeg() {
                    let f = try await MediaTools.runProcess(ffmpeg, ["-hide_banner", "-version"], timeout: 60)
                    let sign = try await MediaTools.runProcess("/usr/bin/codesign", ["-dv", "--verbose=2", ffmpeg], timeout: 60)
                    let authority = sign.stderr.split(separator: "\n").filter { $0.hasPrefix("Authority=") || $0.hasPrefix("TeamIdentifier=") }
                    report += "ffmpeg-status=\(f.status)\nffmpeg=\(f.stdout.split(separator: "\n").first ?? "") at \(ffmpeg)\n"
                        + "ffmpeg-signature=\(authority.joined(separator: "; "))\n"
                } else {
                    report += "ffmpeg-status=missing\nffmpeg-error=\(MediaTools.shared.lastError ?? "")\n"
                }
            } catch {
                report = "error=\(error.localizedDescription)\n"
            }
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
            await MainActor.run { AppDelegate.quitCompletely() }
        }
    }

    static func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }
}
