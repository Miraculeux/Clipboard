// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipboardHistory",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "ClipboardHistory",
            path: "ClipboardHistory",
            exclude: ["ClipboardHistory.entitlements"]
        )
    ]
)
