import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsManager.self) private var settingsManager

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
                Toggle("Launch at Login", isOn: $settingsManager.settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 380)
        .navigationTitle("Settings")
        .onChange(of: settingsManager.settings) {
            settingsManager.save()
        }
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
