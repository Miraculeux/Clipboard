import SwiftUI

struct ClipboardHistoryView: View {
    @EnvironmentObject var clipboardManager: ClipboardManager
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var hoveredItemId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Clipboard History")
                    .font(.headline)
                Spacer()
                Button(action: { openSettings() }) {
                    Image(systemName: "gear")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")

                Button(action: { clipboardManager.clearHistory() }) {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear All")

                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Quit")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search clipboard history...", text: $clipboardManager.searchText)
                    .textFieldStyle(.plain)
                if !clipboardManager.searchText.isEmpty {
                    Button(action: { clipboardManager.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // History list
            if clipboardManager.filteredHistory.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(clipboardManager.searchText.isEmpty ? "No clipboard history yet" : "No matching items")
                        .foregroundColor(.secondary)
                    Text("Copy something to get started")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(clipboardManager.filteredHistory) { item in
                            ClipboardItemRow(
                                item: item,
                                isHovered: hoveredItemId == item.id,
                                onPaste: { clipboardManager.pasteItem(item) },
                                onDelete: { clipboardManager.deleteItem(item) },
                                onPin: { clipboardManager.pinItem(item) },
                                onSaveAs: { saveImageAs(item) }
                            )
                            .onHover { hovering in
                                hoveredItemId = hovering ? item.id : nil
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }

            Divider()

            // Footer
            HStack {
                Text("\(clipboardManager.history.count) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("⌘⇧V to toggle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 350, height: 500)
    }

    private func openSettings() {
        AppDelegate.shared.openSettings()
    }

    private func saveImageAs(_ item: ClipboardItem) {
        guard item.contentType == .image, let sourcePath = item.fileName else { return }
        let sourceURL = URL(fileURLWithPath: sourcePath)

        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        let stamp = ISO8601DateFormatter().string(from: item.timestamp)
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Screenshot \(stamp).png"

        // Make the panel actually appear in front of the popover.
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: sourceURL, to: dest)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t save image"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let isHovered: Bool
    let onPaste: () -> Void
    let onDelete: () -> Void
    let onPin: () -> Void
    let onSaveAs: () -> Void
    @State private var showingImage = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Type icon
            itemIcon
                .frame(width: 24)
                .foregroundColor(.secondary)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                if item.contentType == .image, let fileName = item.fileName {
                    imagePreview(path: fileName)
                } else if item.contentType == .fileURL, let paths = item.filePaths, !paths.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(paths.prefix(3), id: \.self) { path in
                            HStack(spacing: 4) {
                                fileIcon(for: path)
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                            }
                        }
                        if paths.count > 3 {
                            Text("+ \(paths.count - 3) more")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text(item.previewText)
                        .font(.system(size: 12))
                        .lineLimit(3)
                        .foregroundColor(.primary)
                }

                HStack {
                    Text(item.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if item.originalSize > 1000 {
                        Text("• \(item.formattedSize)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Action buttons — always present so hover/click hit-testing
            // stays stable; only the visibility flips on hover.
            HStack(spacing: 6) {
                if item.contentType == .image {
                    Button(action: onSaveAs) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .regular))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Save to…")
                }

                Button(action: onPin) {
                    Image(systemName: "pin")
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Move to top")

                Button(action: onDelete) {
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
        .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            onPaste()
        }
    }

    @ViewBuilder
    private var itemIcon: some View {
        switch item.contentType {
        case .text:
            Image(systemName: "doc.text")
        case .richText:
            Image(systemName: "doc.richtext")
        case .image:
            Image(systemName: "photo")
        case .fileURL:
            Image(systemName: "folder")
        }
    }

    @ViewBuilder
    private func imagePreview(path: String) -> some View {
        if let nsImage = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 80)
                .cornerRadius(4)
        } else {
            Text("Image not found")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func fileIcon(for path: String) -> some View {
        let ext = (path as NSString).pathExtension.lowercased()
        let isDir = {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return isDirectory.boolValue
        }()
        if isDir {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(.blue)
        } else {
            switch ext {
            case "pdf":
                Image(systemName: "doc.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            case "jpg", "jpeg", "png", "gif", "heic", "webp":
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            case "mp4", "mov", "avi", "mkv":
                Image(systemName: "film")
                    .font(.system(size: 11))
                    .foregroundColor(.purple)
            case "zip", "tar", "gz", "rar":
                Image(systemName: "doc.zipper")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            default:
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}
