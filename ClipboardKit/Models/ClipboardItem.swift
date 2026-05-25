import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let contentType: ContentType
    let textContent: String?
    let fileName: String?       // For images/files stored on disk
    let filePaths: [String]?    // For copied files (one or more)
    let originalSize: Int       // Size in bytes
    /// Whether the user has explicitly pinned this item. Pinned items are
    /// shown at the top of the list, never trimmed by the max-history cap,
    /// and survive across launches.
    var isPinned: Bool

    enum ContentType: String, Codable {
        case text
        case richText
        case image
        case fileURL
    }

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         contentType: ContentType,
         textContent: String? = nil,
         fileName: String? = nil,
         filePaths: [String]? = nil,
         originalSize: Int,
         isPinned: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.contentType = contentType
        self.textContent = textContent
        self.fileName = fileName
        self.filePaths = filePaths
        self.originalSize = originalSize
        self.isPinned = isPinned
    }

    /// Custom decoder so payloads written before `isPinned` existed still
    /// decode (defaults to `false`). Encoding is left to the synthesized
    /// `Codable` conformance.
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, contentType, textContent, fileName, filePaths, originalSize, isPinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.contentType = try c.decode(ContentType.self, forKey: .contentType)
        self.textContent = try c.decodeIfPresent(String.self, forKey: .textContent)
        self.fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        self.filePaths = try c.decodeIfPresent([String].self, forKey: .filePaths)
        self.originalSize = try c.decode(Int.self, forKey: .originalSize)
        self.isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
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
