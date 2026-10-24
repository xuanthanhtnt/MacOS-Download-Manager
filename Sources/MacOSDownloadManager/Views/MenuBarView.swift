import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MenuBarView: View {
    @EnvironmentObject var manager: DownloadManager
    @EnvironmentObject var settings: SettingsStore

    private var active: [DownloadItem] {
        manager.items.filter { manager.isRunning($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "MacOS Download Manager").font(.headline)
                    Text(verbatim: active.isEmpty
                         ? String(localized: "No active downloads")
                         : String(format: NSLocalizedString("%d downloading · %@", comment: ""), active.count, Fmt.speed(manager.totalSpeed)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !active.isEmpty {
                Divider()
                ForEach(active.prefix(6)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(verbatim: item.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(verbatim: Fmt.percent(item.progress))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        ProgressView(value: item.progress)
                            .progressViewStyle(.linear)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { WindowManager.shared.showProgress(item.id) }
                }
            }

            Divider()
            Toggle("Speed limiter", isOn: $settings.data.speedLimitEnabled)
            Toggle("Monitor clipboard", isOn: $settings.data.monitorClipboard)

            Divider()
            HStack {
                Button {
                    WindowManager.shared.showAddURL()
                } label: {
                    Label("Add URL", systemImage: "plus")
                }
                Button {
                    WindowManager.shared.showMain()
                } label: {
                    Label("Open MacOS Download Manager", systemImage: "macwindow")
                }
            }
            HStack {
                Button {
                    manager.pauseAll()
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .disabled(active.isEmpty)
                Button {
                    WindowManager.shared.showOptions()
                } label: {
                    Label("Options", systemImage: "gearshape")
                }
                Spacer()
                Button {
                    AppDelegate.quitCompletely()
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .help(String(localized: "Quit MacOS Download Manager completely (downloads stop)"))
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// The small floating window (like IDM's drop target) that accepts links dragged from any app.
struct DropTargetView: View {
    @EnvironmentObject var manager: DownloadManager
    @State private var targeted = false

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.45, blue: 0.95), Color(red: 0.05, green: 0.75, blue: 0.75)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().stroke(Color.white.opacity(targeted ? 0.95 : 0.35), lineWidth: targeted ? 4 : 2))
                .shadow(radius: 4)
            VStack(spacing: 1) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 24, weight: .bold))
                if manager.totalSpeed > 0 {
                    Text(verbatim: Fmt.speed(manager.totalSpeed))
                        .font(.system(size: 8, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(.white)
        }
        .frame(width: 72, height: 72)
        .padding(6)
        .scaleEffect(targeted ? 1.08 : 1)
        .animation(.easeOut(duration: 0.15), value: targeted)
        .onDrop(of: [UTType.url, UTType.plainText], isTargeted: $targeted) { providers in
            DropHandler.handle(providers)
            return true
        }
        .onTapGesture(count: 2) { WindowManager.shared.showMain() }
        .contextMenu {
            Button("Open MacOS Download Manager") { WindowManager.shared.showMain() }
            Button("Add URL…") { WindowManager.shared.showAddURL() }
            Divider()
            Button("Hide Drop Target") { SettingsStore.shared.data.showDropTarget = false }
        }
        .help(Text("Drag links here to download them with MacOS Download Manager"))
    }
}
