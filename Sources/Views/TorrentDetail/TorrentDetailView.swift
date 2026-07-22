import AppKit
import SwiftUI

struct TorrentDetailView: View {
    let torrent: Torrent
    @Environment(TorrentListViewModel.self) private var viewModel
    @Environment(AppNavigationState.self) private var navigationState
    @State private var selectedTab: DetailTab = .files

    private enum DetailTab: String, CaseIterable, Identifiable {
        case files = "Files", trackers = "Trackers", peers = "Peers", settings = "Settings", logs = "Logs"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Picker("", selection: $selectedTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])

            Divider().padding(.top, 8)

            Group {
                switch selectedTab {
                case .files: FilesTab(torrent: torrent)
                case .trackers: TrackersTab(torrent: torrent)
                case .peers: PeersTab(torrent: torrent)
                case .settings: TorrentSettingsTab(torrent: torrent)
                case .logs: LogsTab(torrent: torrent)
                }
            }
            .padding()
        }
        .navigationTitle(torrent.displayName)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(torrent.displayName)
                    .font(.title2.bold())
                    .lineLimit(1)
                Spacer()
                Button {
                    navigationState.detailTorrentID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Details")
            }

            ProgressView(value: torrent.progress)

            HStack(spacing: 20) {
                Label(ByteCountFormatter.string(fromByteCount: torrent.totalSize, countStyle: .binary), systemImage: "shippingbox")
                Label("\(Int(torrent.progress * 100))%", systemImage: "percent")
                Label(torrent.destinationDirectory.path, systemImage: "folder")
                    .lineLimit(1)
                Spacer()
                if torrent.status == .paused {
                    Button("Resume") { viewModel.resume(torrent) }
                } else if torrent.status != .completed && torrent.status != .failed {
                    Button("Pause") { viewModel.pause(torrent) }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct FilesTab: View {
    let torrent: Torrent

    var body: some View {
        if torrent.files.isEmpty {
            ContentUnavailableView("No Files Yet", systemImage: "doc",
                                   description: Text("Waiting for metadata…"))
        } else {
            Table(torrent.files) {
                TableColumn("Path") { file in Text(file.path).lineLimit(1) }
                TableColumn("Size") { file in
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .binary))
                }
                TableColumn("Progress") { file in
                    ProgressView(value: file.size > 0 ? Double(file.downloadedBytes) / Double(file.size) : 0)
                }
                TableColumn("Priority") { file in Text(label(for: file.priority)) }
            }
        }
    }

    private func label(for priority: FilePriority) -> String {
        switch priority {
        case .skip: return "Skip"
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }
}

private struct TrackersTab: View {
    let torrent: Torrent

    var body: some View {
        if torrent.trackers.isEmpty {
            ContentUnavailableView("No Trackers Yet", systemImage: "antenna.radiowaves.left.and.right",
                                   description: Text("Trackers will appear once the torrent starts downloading."))
        } else {
            Table(torrent.trackers) {
                TableColumn("URL") { tracker in Text(tracker.url).lineLimit(1) }
                TableColumn("Tier") { tracker in Text("\(tracker.tier)") }
                TableColumn("Status") { tracker in Text(tracker.status) }
                TableColumn("Peers") { tracker in Text("\(tracker.peersReturned)") }
            }
        }
    }
}

private struct PeersTab: View {
    let torrent: Torrent

    var body: some View {
        if torrent.peers.isEmpty {
            ContentUnavailableView("No Peers Yet", systemImage: "person.2",
                                   description: Text("Peers will appear once the torrent starts downloading."))
        } else {
            Table(torrent.peers) {
                TableColumn("IP") { peer in Text("\(peer.ip):\(peer.port)") }
                TableColumn("Client") { peer in Text(peer.client).lineLimit(1) }
                TableColumn("Down") { peer in
                    Text(ByteCountFormatter.string(fromByteCount: peer.downloadSpeed, countStyle: .binary) + "/s")
                }
                TableColumn("Up") { peer in
                    Text(ByteCountFormatter.string(fromByteCount: peer.uploadSpeed, countStyle: .binary) + "/s")
                }
                TableColumn("Progress") { peer in ProgressView(value: peer.progress) }
            }
        }
    }
}

private struct LogsTab: View {
    let torrent: Torrent

    var body: some View {
        ContentUnavailableView(
            "No Logs Yet",
            systemImage: "doc.text",
            description: Text("Post-download script execution logs will appear here once scripting is implemented.")
        )
    }
}

private struct TorrentSettingsTab: View {
    let torrent: Torrent
    @Environment(TorrentListViewModel.self) private var viewModel
    @State private var renameText = ""

    var body: some View {
        Form {
            Section("Naming") {
                HStack {
                    TextField("Final file name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyRename() }
                    Button("Rename") { applyRename() }
                        .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if torrent.renameRule != nil {
                    Button("Reset to Original Name", role: .destructive) {
                        viewModel.setRenameRule(torrent, finalName: nil)
                        renameText = ""
                    }
                }
            }

            Section("Priority") {
                Picker("Priority", selection: Binding(
                    get: { torrent.priority },
                    set: { viewModel.setPriority(torrent, priority: $0) }
                )) {
                    ForEach(TorrentPriority.allCases, id: \.self) { priority in
                        Text(label(for: priority)).tag(priority)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Destination") {
                HStack {
                    Text(torrent.destinationDirectory.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Move…") { chooseDestination() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { renameText = torrent.renameRule?.finalName ?? "" }
    }

    private func applyRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        viewModel.setRenameRule(torrent, finalName: trimmed)
    }

    private func label(for priority: TorrentPriority) -> String {
        switch priority {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = torrent.destinationDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.setDestination(torrent, to: url)
    }
}
