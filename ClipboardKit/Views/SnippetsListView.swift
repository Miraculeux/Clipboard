import SwiftUI
import AppKit

/// Snippet library tab in the popover. Mirrors the structure of
/// `HistoryListView` (empty state + scrollable list) so the user sees a
/// familiar layout when switching tabs.
struct SnippetsListView: View {
    @EnvironmentObject var clipboardManager: ClipboardManager
    @State private var editing: SnippetEditState?

    var body: some View {
        VStack(spacing: 0) {
            // "+ New" header row: gives the empty-state a way to bootstrap
            // and keeps creating-a-snippet one click away when the list is
            // populated.
            HStack {
                Button {
                    editing = .new
                } label: {
                    Label("New Snippet", systemImage: "plus.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if clipboardManager.filteredSnippets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.star")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(emptyMessage)
                        .foregroundColor(.secondary)
                    Text("Save text from history or create a new one")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(clipboardManager.filteredSnippets.enumerated()), id: \.element.id) { index, snippet in
                                SnippetRow(
                                    snippet: snippet,
                                    isKeyboardSelected: snippet.id == clipboardManager.keyboardSelectedSnippetID,
                                    quickPasteNumber: index < 9 ? index + 1 : nil,
                                    onEdit: { editing = .edit(snippet) }
                                )
                                .id(snippet.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: clipboardManager.keyboardSelectedSnippetID) { _, newID in
                        if let newID {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                proxy.scrollTo(newID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { state in
            SnippetEditorView(state: state) { result in
                switch result {
                case .create(let snippet):
                    clipboardManager.addSnippet(snippet)
                case .update(let snippet):
                    clipboardManager.updateSnippet(snippet)
                case .delete(let snippet):
                    clipboardManager.deleteSnippet(snippet)
                case .cancel:
                    break
                }
                editing = nil
            }
        }
    }

    private var emptyMessage: String {
        clipboardManager.searchText.isEmpty ? "No snippets yet" : "No matching snippets"
    }
}

/// Identifier for the snippet editor sheet. Carries the snippet to edit, or
/// `.new` for a blank one.
enum SnippetEditState: Identifiable {
    case new
    case edit(Snippet)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let s): return s.id.uuidString
        }
    }
}

struct SnippetRow: View {
    let snippet: Snippet
    let isKeyboardSelected: Bool
    /// 1-based shortcut number (⌘N). `nil` for rows beyond the ninth.
    let quickPasteNumber: Int?
    let onEdit: () -> Void
    @EnvironmentObject private var manager: ClipboardManager
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                if let n = quickPasteNumber {
                    Text("⌘\(n)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary.opacity(0.7)))
                        .help("Press ⌘\(n) to paste this snippet")
                } else {
                    Image(systemName: "text.badge.star")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(snippet.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !snippet.abbreviation.isEmpty {
                        Text(snippet.abbreviation)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(.quaternary.opacity(0.6))
                            )
                            .foregroundStyle(.secondary)
                    }
                }
                Text(snippet.previewBody)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: 6) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Edit")

                Button(action: { manager.deleteSnippet(snippet) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 16, height: 16)
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(8)
        .background(rowBackground)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            manager.pasteSnippet(
                snippet,
                transform: PasteTransform.from(modifiers: NSEvent.modifierFlags)
            )
        }
        .onHover { hovering in isHovered = hovering }
        .contextMenu {
            Button("Paste") { manager.pasteSnippet(snippet) }
            Button("Paste as Plain Text") { manager.pasteSnippet(snippet, transform: .plainText) }
                .keyboardShortcut(.return, modifiers: [.option])
            Button("Paste Trimmed") { manager.pasteSnippet(snippet, transform: .trimmed) }
                .keyboardShortcut(.return, modifiers: [.shift])
            Menu("Paste as…") {
                Button("lowercase")  { manager.pasteSnippet(snippet, transform: .lowercase) }
                    .keyboardShortcut(.return, modifiers: [.control])
                Button("UPPERCASE")  { manager.pasteSnippet(snippet, transform: .uppercase) }
                    .keyboardShortcut(.return, modifiers: [.control, .shift])
                Button("Title Case") { manager.pasteSnippet(snippet, transform: .titleCase) }
                    .keyboardShortcut(.return, modifiers: [.control, .option])
            }
            Divider()
            Button("Edit…", action: onEdit)
            Button("Delete", role: .destructive) { manager.deleteSnippet(snippet) }
        }
    }

    private var rowBackground: Color {
        if isKeyboardSelected { return Color.accentColor.opacity(0.12) }
        if isHovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }
}

/// Modal sheet for creating or editing a snippet. Returns the result back
/// through `onResult` so the parent owns the persistence side-effects.
struct SnippetEditorView: View {
    let state: SnippetEditState
    let onResult: (Result) -> Void

    enum Result {
        case create(Snippet)
        case update(Snippet)
        case delete(Snippet)
        case cancel
    }

    @State private var title: String
    @State private var content: String
    @State private var abbreviation: String

    init(state: SnippetEditState, onResult: @escaping (Result) -> Void) {
        self.state = state
        self.onResult = onResult
        switch state {
        case .new:
            _title = State(initialValue: "")
            _content = State(initialValue: "")
            _abbreviation = State(initialValue: "")
        case .edit(let s):
            _title = State(initialValue: s.title)
            _content = State(initialValue: s.content)
            _abbreviation = State(initialValue: s.abbreviation)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.isNew ? "New Snippet" : "Edit Snippet")
                .font(.headline)
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                TextField("Abbreviation (e.g. ;sig)", text: $abbreviation)
                    .textFieldStyle(.roundedBorder)
                    .help("Type this trigger anywhere on macOS to auto-expand the snippet. Requires the abbreviation expander to be enabled in Settings.")
            }
            TextEditor(text: $content)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
            Text("Variables: {date}, {date:yyyy-MM-dd}, {time}, {datetime}, {clipboard}, {uuid}")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack {
                if case .edit(let s) = state {
                    Button(role: .destructive) {
                        onResult(.delete(s))
                    } label: {
                        Text("Delete")
                    }
                }
                Spacer()
                Button("Cancel") { onResult(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func save() {
        let trimmedContent = content
        let trimmedAbbrev = abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state {
        case .new:
            onResult(.create(Snippet(title: title, content: trimmedContent, abbreviation: trimmedAbbrev)))
        case .edit(var s):
            s.title = title
            s.content = trimmedContent
            s.abbreviation = trimmedAbbrev
            onResult(.update(s))
        }
    }
}

private extension SnippetEditState {
    var isNew: Bool {
        if case .new = self { return true }
        return false
    }
}
