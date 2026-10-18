// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacOSDownloadManager",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacOSDownloadManager",
            path: "Sources/MacOSDownloadManager"
        ),
        .testTarget(
            name: "MacOSDownloadManagerTests",
            dependencies: ["MacOSDownloadManager"],
            path: "Tests/MacOSDownloadManagerTests"
        )
    ]
)
