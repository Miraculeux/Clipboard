import Foundation

/// Cached metadata for a URL clipboard item. Fetched once via
/// `LPMetadataProvider`, then persisted alongside the item so the rich
/// preview survives relaunches. Heavy assets (thumbnail, favicon) live on
/// disk in the app-support cache directory; only their paths travel here.
struct LinkPreview: Codable, Equatable {
    /// Canonical URL string the metadata was fetched for.
    var url: String
    /// Title from `LPLinkMetadata.title` if available.
    var title: String?
    /// Host portion of the URL, used as a small line under the title.
    var domain: String
    /// On-disk path to the OG image thumbnail, if one was extracted.
    var imagePath: String?
    /// On-disk path to the favicon, if one was extracted.
    var iconPath: String?
    /// When the fetch completed. Lets us refresh stale previews later.
    var fetchedAt: Date
    /// `true` if the fetch returned no metadata (DNS failure, 404, blocked).
    /// We still persist the record so the UI doesn't keep retrying every
    /// time the row renders.
    var failed: Bool

    init(url: String,
         title: String? = nil,
         domain: String,
         imagePath: String? = nil,
         iconPath: String? = nil,
         fetchedAt: Date = Date(),
         failed: Bool = false) {
        self.url = url
        self.title = title
        self.domain = domain
        self.imagePath = imagePath
        self.iconPath = iconPath
        self.fetchedAt = fetchedAt
        self.failed = failed
    }
}

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
    /// Rich preview for URL text items, populated asynchronously after the
    /// item is added. `nil` for non-URL items or while the fetch is in
    /// flight. `LinkPreview.failed == true` means we tried and gave up.
    var linkPreview: LinkPreview?

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
         isPinned: Bool = false,
         linkPreview: LinkPreview? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.contentType = contentType
        self.textContent = textContent
        self.fileName = fileName
        self.filePaths = filePaths
        self.originalSize = originalSize
        self.isPinned = isPinned
        self.linkPreview = linkPreview
    }

    /// Custom decoder so payloads written before `isPinned` / `linkPreview`
    /// existed still decode (they default to `false` / `nil`). Encoding is
    /// left to the synthesized `Codable` conformance.
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, contentType, textContent, fileName, filePaths,
             originalSize, isPinned, linkPreview
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
        self.linkPreview = try c.decodeIfPresent(LinkPreview.self, forKey: .linkPreview)
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
