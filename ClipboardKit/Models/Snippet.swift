import Foundation

/// User-curated text template, kept separate from the auto-captured clipboard
/// history. Snippets never expire and aren't subject to the history cap; the
/// user owns the full lifecycle (create / edit / delete).
struct Snippet: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var title: String
    var content: String
    /// Optional trigger string typed by the user. When the global
    /// abbreviation expander is enabled and `abbreviation` is non-empty,
    /// typing it anywhere on macOS (followed by a word boundary) will delete
    /// the trigger and paste this snippet's expanded body. Empty means the
    /// snippet only fires on explicit click / shortcut from the popover.
    var abbreviation: String
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         title: String,
         content: String,
         abbreviation: String = "",
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.abbreviation = abbreviation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Back-compat decoder: snippets written before `abbreviation` shipped
    /// default to an empty trigger.
    private enum CodingKeys: String, CodingKey {
        case id, title, content, abbreviation, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.content = try c.decode(String.self, forKey: .content)
        self.abbreviation = try c.decodeIfPresent(String.self, forKey: .abbreviation) ?? ""
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    /// Short preview shown in the snippet row when the title is empty (the
    /// title field is optional from the user's POV — a quick "save selection
    /// as snippet" lets them skip naming it).
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = content
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? ""
        let preview = firstLine.trimmingCharacters(in: .whitespaces)
        return preview.isEmpty ? "Untitled snippet" : String(preview.prefix(60))
    }

    var previewBody: String {
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count > 200 { return String(body.prefix(200)) + "…" }
        return body
    }
}
