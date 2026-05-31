import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var historyCountText: String = ""
    @State private var showClearConfirmation = false
    @State private var selection: Section = .general

    /// The settings sections that appear in the sidebar. Order = display order.
    private enum Section: String, CaseIterable, Identifiable {
        case general, shortcuts, screenshot, storage, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general:    return "General"
            case .shortcuts:  return "Shortcuts"
            case .screenshot: return "Screenshot"
            case .storage:    return "Storage"
            case .about:      return "About"
            }
        }
        var systemImage: String {
            switch self {
            case .general:    return "gearshape"
            case .shortcuts:  return "keyboard"
            case .screenshot: return "camera.viewfinder"
            case .storage:    return "externaldrive"
            case .about:      return "info.circle"
            }
        }
        /// Tint applied to the icon — gives each row a recognisable colour
        /// the same way macOS System Settings does.
        var tint: Color {
            switch self {
            case .general:    return .gray
            case .shortcuts:  return .blue
            case .screenshot: return .orange
            case .storage:    return .purple
            case .about:      return .green
            }
        }
    }

    var body: some View {
        // macOS-style preferences window: tabs at the top, each tab is a
        // scrollable form. This is the idiomatic shape for the SwiftUI
        // `Settings { }` scene and avoids the empty toolbar / sidebar
        // chrome issues NavigationSplitView shows there on macOS 26.
        TabView(selection: $selection) {
            ForEach(Section.allCases) { section in
                ScrollView {
                    content(for: section)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .tabItem {
                    Label(section.title, systemImage: section.systemImage)
                }
                .tag(section)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 460, idealHeight: 520)
        .onAppear {
            historyCountText = "\(settings.maxHistoryCount)"
        }
    }

    @ViewBuilder
    private func content(for section: Section) -> some View {
        switch section {
        case .general:    generalTab
        case .shortcuts:  shortcutsTab
        case .screenshot: screenshotTab
        case .storage:    storageTab
        case .about:      aboutTab
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("History") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("Max items:")
                            .gridColumnAlignment(.trailing)
                        HStack(spacing: 8) {
                            TextField("", text: $historyCountText)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.center)
                                .onChange(of: historyCountText) { _, newValue in
                                    if let count = Int(newValue), count > 0, count <= 9999 {
                                        settings.maxHistoryCount = count
                                    }
                                }
                            Stepper("", value: $settings.maxHistoryCount, in: 1...9999, step: 50)
                                .labelsHidden()
                                .onChange(of: settings.maxHistoryCount) { _, newValue in
                                    historyCountText = "\(newValue)"
                                }
                            Text("1 – 9999")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("")
                        Toggle("Merge duplicate entries (re-copying floats the existing row to the top)",
                               isOn: $settings.deduplicateEntries)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Behavior") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    Toggle("Show notification when item is captured", isOn: $settings.showNotifications)
                    Toggle("Always paste as plain text (strip formatting)", isOn: $settings.alwaysPastePlainText)
                    Toggle("Restore previous clipboard after paste", isOn: $settings.restoreClipboardAfterPaste)
                    Text("Paste modifiers: ⌥ plain text · ⇧ trimmed · ⌃ lowercase · ⌃⇧ UPPERCASE · ⌃⌥ Title Case")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Snippets") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Expand snippet abbreviations as you type",
                           isOn: $settings.snippetAbbreviationsEnabled)
                    Text("Requires Accessibility permission. Typing a snippet's abbreviation followed by space / punctuation will replace it with the snippet body.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Screen capture requires Screen Recording permission. After rebuilds you may need to toggle ClipboardKit off and on again in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Screen Recording Settings…") {
                        ScreenRecordingPermission.openScreenRecordingSettings()
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Global Shortcuts") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    ForEach(HotkeyAction.allCases, id: \.self) { action in
                        GridRow {
                            // Wrap instead of truncate \u2014 some action labels
                            // (e.g. "Long (scrolling) screenshot") are wider
                            // than the column at the default Settings size,
                            // and ellipsizing made them unreadable.
                            Text(action.title)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minWidth: 220, alignment: .leading)
                            HotkeyRecorderView(action: action, settings: settings)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("Press Esc while recording to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Screenshot Tab

    private var screenshotTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Capture") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("Delay:")
                            .gridColumnAlignment(.trailing)
                        Picker("", selection: $settings.captureDelaySeconds) {
                            Text("None").tag(0)
                            Text("3s").tag(3)
                            Text("5s").tag(5)
                            Text("10s").tag(10)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    GridRow {
                        Text("Post-capture:")
                            .gridColumnAlignment(.trailing)
                        Toggle("Show floating thumbnail (click to annotate)",
                               isOn: $settings.showCaptureThumbnail)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Save to Disk") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Also save each screenshot as a PNG file",
                           isOn: $settings.saveScreenshotsToDisk)

                    if settings.saveScreenshotsToDisk {
                        HStack {
                            Text(settings.screenshotsFolderPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Browse…") {
                                if let p = settings.selectScreenshotsFolder() {
                                    settings.screenshotsFolderPath = p
                                }
                            }
                            Button("Reveal in Seeker") {
                                revealInSeeker(path: settings.screenshotsFolderPath)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Storage Tab

    private var storageTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Large File Threshold") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Store separately when larger than:")
                        Stepper("\(settings.largeFileThresholdMB) MB", value: $settings.largeFileThresholdMB, in: 1...100)
                    }
                    Text("Images and data above this size are saved to the storage location below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("Storage Location") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(settings.largeFileStoragePath)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(6)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)

                    HStack(spacing: 12) {
                        Button("Browse…") {
                            if let path = settings.selectStorageFolder() {
                                settings.largeFileStoragePath = path
                                settings.ensureStorageDirectoryExists()
                            }
                        }
                        Button("Reveal in Seeker") {
                            revealInSeeker(path: settings.largeFileStoragePath)
                        }
                        Spacer()
                        Button("Clear All Files…") {
                            showClearConfirmation = true
                        }
                        .foregroundStyle(.red)
                        .alert("Clear all stored files?", isPresented: $showClearConfirmation) {
                            Button("Cancel", role: .cancel) {}
                            Button("Clear", role: .destructive) {
                                clearStoredFiles()
                            }
                        } message: {
                            Text("This will delete all cached images and large files. Clipboard text history is not affected.")
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clipboard")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Clipboard History")
                .font(.title2.bold())

            Text("Version 1.0.0")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("A clipboard history manager for macOS.\nPress ⌘⇧V to open your clipboard history.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: - Helpers

    /// Ask Seeker (com.marvel.Seeker) to reveal a file or folder. Thin
    /// wrapper around the shared implementation in `UrlActions`.
    private func revealInSeeker(path: String) {
        UrlActions.revealInSeeker(path: path)
    }

    private func clearStoredFiles() {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: settings.largeFileStoragePath) {
            for file in files {
                let path = (settings.largeFileStoragePath as NSString).appendingPathComponent(file)
                try? fm.removeItem(atPath: path)
            }
        }
    }
}
