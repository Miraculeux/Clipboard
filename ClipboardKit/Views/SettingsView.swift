import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var historyCountText: String = ""
    @State private var showClearConfirmation = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            storageTab
                .tabItem {
                    Label("Storage", systemImage: "externaldrive")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 320)
        .onAppear {
            historyCountText = "\(settings.maxHistoryCount)"
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("History") {
                Grid(alignment: .leading, verticalSpacing: 10) {
                    GridRow {
                        Text("Max items:")
                            .frame(width: 120, alignment: .trailing)
                        HStack(spacing: 8) {
                            TextField("", text: $historyCountText)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.center)
                                .onChange(of: historyCountText) { _, newValue in
                                    if let count = Int(newValue), count > 0, count <= 1000 {
                                        settings.maxHistoryCount = count
                                    }
                                }
                            Stepper("", value: $settings.maxHistoryCount, in: 1...1000, step: 10)
                                .labelsHidden()
                                .onChange(of: settings.maxHistoryCount) { _, newValue in
                                    historyCountText = "\(newValue)"
                                }
                            Text("1 – 1000")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Notifications:")
                            .frame(width: 120, alignment: .trailing)
                        Toggle("Show when item is captured", isOn: $settings.showNotifications)
                    }
                    GridRow {
                        Text("Startup:")
                            .frame(width: 120, alignment: .trailing)
                        Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    }
                }
                .padding(8)
            }

            GroupBox("Shortcut") {
                HStack(spacing: 8) {
                    Text("⌘⇧V")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                    Text("Toggle clipboard history panel")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .padding(8)
            }

            Spacer()
        }
        .padding(16)
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
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: settings.largeFileStoragePath))
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

            Spacer()
        }
        .padding(16)
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
