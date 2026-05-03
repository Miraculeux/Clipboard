// swift-tools-version: 5.9
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
