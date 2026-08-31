import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(TorrentListViewModel.self) private var listViewModel

    @State private var editingTag: Tag?
    @State private var isPresentingTagEditor = false

    var body: some View {
        @Bindable var settingsManager = settingsManager

        Form {
            Section("Downloads") {
                LabeledContent("Download Folder") {
                    HStack {
                        Text(settingsManager.settings.defaultDownloadDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseDownloadFolder() }
                    }
                }
                Stepper(
                    "Max Parallel Downloads: \(settingsManager.settings.maxParallelDownloads)",
                    value: $settingsManager.settings.maxParallelDownloads,
                    in: 1...20
                )
            }

            Section("Speed Limits") {
                SpeedLimitField(title: "Download Limit", limit: $settingsManager.settings.globalDownloadLimitBytesPerSec)
                SpeedLimitField(title: "Upload Limit", limit: $settingsManager.settings.globalUploadLimitBytesPerSec)
            }

            Section("General") {
                Toggle("Enable Notifications", isOn: $settingsManager.settings.notificationsEnabled)
                Toggle("Play Sound When a Download Completes", isOn: $settingsManager.settings.completionSoundEnabled)
                Toggle("Launch at Login", isOn: $settingsManager.settings.launchAtLogin)
            }

            Section("Tags") {
                if settingsManager.settings.tags.isEmpty {
                    Text("No tags yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settingsManager.settings.tags) { tag in
                    HStack {
                        Circle().fill(tag.color).frame(width: 12, height: 12)
                        Text(tag.name)
                        if tag.scriptPath != nil {
                            Image(systemName: "terminal")
                                .foregroundStyle(.secondary)
                                .help("Runs a script on completion")
                        }
                        Spacer()
                        Button("Edit") {
                            editingTag = tag
                            isPresentingTagEditor = true
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            removeTag(tag)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Tag…") {
                    editingTag = nil
                    isPresentingTagEditor = true
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 380)
        .navigationTitle("Settings")
        .onChange(of: settingsManager.settings) {
            settingsManager.save()
        }
        .sheet(isPresented: $isPresentingTagEditor) {
            TagEditorSheet(tag: editingTag) { tag in
                upsertTag(tag)
            }
        }
    }

    private func upsertTag(_ tag: Tag) {
        if let index = settingsManager.settings.tags.firstIndex(where: { $0.id == tag.id }) {
            settingsManager.settings.tags[index] = tag
        } else {
            settingsManager.settings.tags.append(tag)
        }
    }

    private func removeTag(_ tag: Tag) {
        settingsManager.settings.tags.removeAll { $0.id == tag.id }
        listViewModel.clearTag(tag.id)
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settingsManager.settings.defaultDownloadDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settingsManager.settings.defaultDownloadDirectory = url
    }
}

private struct SpeedLimitField: View {
    let title: String
    @Binding var limit: Int?

    @State private var isEnabled = false
    @State private var kbPerSecond: Double = 0

    var body: some View {
        HStack {
            Toggle(title, isOn: $isEnabled)
                .onChange(of: isEnabled) { _, enabled in
                    limit = enabled ? Int(kbPerSecond * 1024) : nil
                }
            if isEnabled {
                TextField("KB/s", value: $kbPerSecond, format: .number)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: kbPerSecond) { _, value in
                        limit = Int(value * 1024)
                    }
                Text("KB/s")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            isEnabled = limit != nil
            kbPerSecond = Double(limit ?? 0) / 1024
        }
    }
}
