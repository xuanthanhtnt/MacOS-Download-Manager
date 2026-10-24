import SwiftUI
import AppKit

/// Browsers the extension works with, and how to reach their extensions page.
struct KnownBrowser: Identifiable {
    let id: String // bundle identifier
    let name: String
    let extensionsPage: String
    let chromium: Bool

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    static let all: [KnownBrowser] = [
        KnownBrowser(id: "com.brave.Browser", name: "Brave", extensionsPage: "brave://extensions", chromium: true),
        KnownBrowser(id: "com.google.Chrome", name: "Google Chrome", extensionsPage: "chrome://extensions", chromium: true),
        KnownBrowser(id: "com.microsoft.edgemac", name: "Microsoft Edge", extensionsPage: "edge://extensions", chromium: true),
        KnownBrowser(id: "company.thebrowser.Browser", name: "Arc", extensionsPage: "arc://extensions", chromium: true),
        KnownBrowser(id: "com.vivaldi.Vivaldi", name: "Vivaldi", extensionsPage: "vivaldi://extensions", chromium: true),
        KnownBrowser(id: "com.operasoftware.Opera", name: "Opera", extensionsPage: "opera://extensions", chromium: true),
        KnownBrowser(id: "org.chromium.Chromium", name: "Chromium", extensionsPage: "chrome://extensions", chromium: true),
        KnownBrowser(id: "org.mozilla.firefox", name: "Firefox", extensionsPage: "about:debugging#/runtime/this-firefox", chromium: false)
    ]

    static var installed: [KnownBrowser] { all.filter { $0.appURL != nil } }
}

enum ExtensionSetup {
    private static let shownKey = "MDM.extensionSetupShown"

    /// Browsers do not let apps install extensions themselves: guide the user once, on the first launch.
    static func showOnFirstLaunchIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard ExtensionStatus.shared.version == nil,
              !UserDefaults.standard.bool(forKey: shownKey),
              !env.keys.contains(where: { $0.hasPrefix("MDM_SELFTEST") }),
              !KnownBrowser.installed.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: shownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { WindowManager.shared.showExtensionSetup() }
    }

    /// Opens the browser's extensions page (the address is also copied, in case the browser ignores it).
    static func openExtensionsPage(_ browser: KnownBrowser) {
        ClipboardMonitor.shared.ignoreCurrentChange()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(browser.extensionsPage, forType: .string)
        ClipboardMonitor.shared.ignoreCurrentChange()
        guard let app = browser.appURL, let page = URL(string: browser.extensionsPage) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([page], withApplicationAt: app, configuration: configuration)
    }
}

/// "Add to Browser" assistant: open the extensions page, turn on Developer mode, drag the folder in.
struct ExtensionSetupView: View {
    @ObservedObject private var status = ExtensionStatus.shared
    @State private var folder: URL? = BrowserExtensionInstaller.prepareInstalledCopy(firefox: false)
    @State private var opened: String?
    private let browsers = KnownBrowser.installed

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add MacOS Download Manager to your browser").font(.title3.weight(.semibold))
                    Text("With the extension, downloads and YouTube videos go straight to the app. It takes three steps, once – afterwards the extension updates itself together with the app.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let version = status.version, !status.isOutdated {
                Label(String(format: String(localized: "Connected – extension v%@ is working"), version), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            }

            step(1, "Open the extensions page") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(browsers.filter(\.chromium)) { browser in
                            Button {
                                ExtensionSetup.openExtensionsPage(browser)
                                opened = browser.extensionsPage
                            } label: {
                                HStack(spacing: 6) {
                                    if let app = browser.appURL {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                            .resizable()
                                            .frame(width: 18, height: 18)
                                    }
                                    Text(verbatim: browser.name)
                                }
                            }
                        }
                    }
                    if let opened {
                        Text(String(format: String(localized: "If the page did not open, paste the copied address (%@) into the browser's address bar."), opened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            step(2, "Turn on “Developer mode”") {
                Text("The switch is at the top right of the extensions page.")
                    .foregroundStyle(.secondary)
            }

            step(3, "Drag this folder onto the extensions page") {
                HStack(spacing: 14) {
                    if let folder {
                        VStack(spacing: 4) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                                .resizable()
                                .frame(width: 52, height: 52)
                            Text(verbatim: folder.lastPathComponent).font(.caption.weight(.semibold))
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                        .onDrag { NSItemProvider(object: folder as NSURL) }
                        .help(String(localized: "Drag me onto the browser's extensions page"))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Drop it anywhere on the page. Or click “Load unpacked” there and choose this folder.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        }
                    } else {
                        Text("The extension folder could not be prepared.").foregroundStyle(.red)
                    }
                }
            }

            if browsers.contains(where: { !$0.chromium }) {
                Text("Firefox: open about:debugging → This Firefox → “Load Temporary Add-on…” and choose manifest.json in the “firefox” folder (Firefox removes it when it quits).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Browsers only let you add extensions yourself – no app can do it for you, for your safety.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(status.version == nil ? "Later" : "Done") { WindowManager.shared.close("extension-setup") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    private func step<Content: View>(_ number: Int, _ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
            Spacer(minLength: 0)
        }
    }
}
