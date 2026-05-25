import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let contentType: ContentType
    let textContent: String?
    let fileName: String?       // For images/files stored on disk
    let filePaths: [String]?    // For copied files (one or more)
    let originalSize: Int       // Size in bytes

    enum ContentType: String, Codable {
        case text
        case richText
        case image
        case fileURL
    }

    var displayText: String {
        switch contentType {
        case .text, .richText:
            return textContent ?? "(empty)"
        case .image:
            return "📷 Image (\(formattedSize))"
        case .fileURL:
            if let paths = filePaths, !paths.isEmpty {
                if paths.count == 1 {
                    let name = (paths[0] as NSString).lastPathComponent
                    return "📁 \(name)"
                } else {
                    let firstName = (paths[0] as NSString).lastPathComponent
                    return "📁 \(firstName) + \(paths.count - 1) more"
                }
            }
            return "📁 \(textContent ?? "File")"
        }
    }

    var previewText: String {
        let text = displayText
        if text.count > 200 {
            return String(text.prefix(200)) + "..."
        }
        return text
    }

    var formattedSize: String {
        Self.byteFormatter.string(fromByteCount: Int64(originalSize))
    }

    /// Reused across all rows; `ByteCountFormatter` is documented as
    /// thread-safe for `string(fromByteCount:)`. Per-call construction was
    /// hot during list scroll because every visible row formats its size.
    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var isLargeFile: Bool {
        return originalSize > 1_000_000 // > 1MB
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
    }
}
