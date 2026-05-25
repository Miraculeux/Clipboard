// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClipboardKit",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "ClipboardKit",
            path: "ClipboardKit",
            exclude: ["ClipboardKit.entitlements"]
        )
    ]
)
