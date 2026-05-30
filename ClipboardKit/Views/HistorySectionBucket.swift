import Foundation
import SwiftUI

/// One temporal slice of the clipboard history. Pinned items live in a
/// dedicated section pinned to the very top so the user never has to scroll
/// past fresh-but-uninteresting captures to reach a curated pin.
struct HistorySectionBucket: Identifiable {
    let id: String
    let title: String
    let entries: [Entry]

    struct Entry {
        let index: Int
        let item: ClipboardItem
    }

    /// Group `indexedItems` (preserving order) into sections. Buckets:
    /// "Pinned" → "Today" → "Yesterday" → "Earlier this week" → "Older".
    /// Empty buckets are dropped.
    static func bucketize(_ indexedItems: [(offset: Int, element: ClipboardItem)]) -> [HistorySectionBucket] {
        let now = Date()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        guard let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday),
              let weekAgo = cal.date(byAdding: .day, value: -7, to: startOfToday) else {
            // Pathological calendar failure — fall back to a single bucket.
            return [HistorySectionBucket(
                id: "all", title: "All",
                entries: indexedItems.map { Entry(index: $0.offset, item: $0.element) }
            )]
        }

        var pinned: [Entry] = []
        var today: [Entry] = []
        var yesterday: [Entry] = []
        var week: [Entry] = []
        var older: [Entry] = []

        for (index, item) in indexedItems {
            let e = Entry(index: index, item: item)
            if item.isPinned {
                pinned.append(e); continue
            }
            let t = item.timestamp
            if t >= startOfToday          { today.append(e) }
            else if t >= startOfYesterday { yesterday.append(e) }
            else if t >= weekAgo          { week.append(e) }
            else                          { older.append(e) }
        }

        var result: [HistorySectionBucket] = []
        if !pinned.isEmpty    { result.append(.init(id: "pinned",    title: "Pinned",            entries: pinned)) }
        if !today.isEmpty     { result.append(.init(id: "today",     title: "Today",             entries: today)) }
        if !yesterday.isEmpty { result.append(.init(id: "yesterday", title: "Yesterday",         entries: yesterday)) }
        if !week.isEmpty      { result.append(.init(id: "week",      title: "Earlier this week", entries: week)) }
        if !older.isEmpty     { result.append(.init(id: "older",     title: "Older",             entries: older)) }
        return result
    }
}

/// Sticky section header rendered above each bucket. Uses a translucent
/// header-material backing so the row content under it stays readable
/// as it scrolls past.
struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary.opacity(0.5)))
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(VisualEffectBackground(material: .headerView, blendingMode: .withinWindow))
    }
}
