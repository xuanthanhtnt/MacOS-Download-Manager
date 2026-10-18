import SwiftUI
import AppKit

enum AppInfo {
    static let developer = "xuanthanhtnt"
    static let repository = "https://github.com/xuanthanhtnt/MacOS-Download-Manager"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Opens a new GitHub issue with the app and macOS versions already filled in.
    static func reportBug() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let body = """
        **App version:** \(version) (\(build))
        **macOS:** \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        **Mac:** \(machine)

        **What happened / Mô tả lỗi:**


        **Steps to reproduce / Các bước tái hiện:**
        1.

        **Link (if any) / Link tải (nếu có):**

        """
        var components = URLComponents(string: repository + "/issues/new")
        components?.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = components?.url {
            NSWorkspace.shared.open(url)
        }
    }

    private static var machine: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text(verbatim: "MacOS Download Manager")
                    .font(.title2.weight(.bold))
                Text(verbatim: String(format: NSLocalizedString("Version %@ (%@)", comment: ""), AppInfo.version, AppInfo.build))
                    .foregroundStyle(.secondary)
            }
            Text("A fast multi-connection download manager for macOS.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Developer").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(verbatim: AppInfo.developer).fontWeight(.semibold)
                }
                GridRow {
                    Text("Website").foregroundStyle(.secondary)
                    Link(destination: URL(string: AppInfo.repository)!) {
                        Text(verbatim: "github.com/\(AppInfo.developer)/MacOS-Download-Manager")
                    }
                }
                GridRow {
                    Text("License").foregroundStyle(.secondary)
                    Text(verbatim: "MIT")
                }
            }

            Button {
                AppInfo.reportBug()
            } label: {
                Label("Report a Bug…", systemImage: "ladybug.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Video downloads use the open-source projects yt-dlp, Deno and, when installed, FFmpeg.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "© 2026 \(AppInfo.developer)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 400)
    }
}
