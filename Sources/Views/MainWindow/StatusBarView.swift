import SwiftUI

/// Thin strip across the bottom of the window reporting how much room is left for downloads,
/// i.e. on the volume holding the default download directory — and, when anything is still
/// waiting to be written, where that figure is headed once it has been.
struct StatusBarView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(TorrentListViewModel.self) private var listViewModel

    @State private var availableBytes: Int64?

    private var downloadDirectory: URL {
        settingsManager.settings.defaultDownloadDirectory
    }

    var body: some View {
        HStack(spacing: 6) {
            Spacer()
            if let projection {
                Text(projection.text)
                    .monospacedDigit()
                    .foregroundStyle(projection.isShortfall ? Color.red : Color.secondary)
                    .help(projection.isShortfall
                          ? "Everything still to be downloaded doesn't fit in the free space"
                          : "What will be left once every unfinished torrent has downloaded")
                Text("·")
            }
            Image(systemName: "internaldrive")
            Text(freeLabel)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .help("Free space on the volume holding \(downloadDirectory.path)")
        // Re-measured on a loop because the number drifts the whole time torrents are writing,
        // and restarted outright whenever a torrent is added or removed — those are the moments
        // the figure jumps, and waiting out the rest of a poll interval to show it would make
        // the bar look stuck. Adding a torrent also moves the projection below, but that one is
        // derived from the list directly and needs no measuring.
        .task(id: refreshTrigger) {
            while !Task.isCancelled {
                let directory = downloadDirectory
                availableBytes = await Task.detached { Self.availableCapacity(for: directory) }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private struct RefreshTrigger: Equatable {
        var directory: URL
        var membershipRevision: Int
    }

    private var refreshTrigger: RefreshTrigger {
        RefreshTrigger(directory: downloadDirectory, membershipRevision: listViewModel.membershipRevision)
    }

    private var freeLabel: String {
        guard let availableBytes else { return "— free" }
        return Self.byteFormatter.string(fromByteCount: availableBytes) + " free"
    }

    private struct Projection {
        var text: String
        var isShortfall: Bool
    }

    /// The figure to the left of the free-space one: where the volume lands once everything
    /// still queued or in flight has been written. `nil` when there is nothing to project —
    /// including when rounding would print the very same number twice.
    private var projection: Projection? {
        guard let availableBytes else { return nil }
        let pending = listViewModel.pendingDownloadBytes
        guard pending > 0 else { return nil }

        let projected = availableBytes - pending
        guard projected >= 0 else {
            return Projection(text: Self.byteFormatter.string(fromByteCount: -projected) + " short", isShortfall: true)
        }

        let text = Self.byteFormatter.string(fromByteCount: projected)
        guard text != Self.byteFormatter.string(fromByteCount: availableBytes) else { return nil }
        return Projection(text: text + " after downloads", isShortfall: false)
    }

    // Decimal (`.file`) rather than the binary style the rest of the app uses for transfer
    // sizes: this number exists to be checked against what Finder says about the disk.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// Space the volume would actually hand to a download. `volumeAvailableCapacityForImportantUsage`
    /// is the figure Finder shows — it includes purgeable space macOS would evict to make room,
    /// which the raw free-block count leaves out.
    /// `nonisolated` so the measurement can run off the main actor: conforming to `View` puts
    /// the whole type on it, and a volume lookup is a filesystem round trip.
    private nonisolated static func availableCapacity(for directory: URL) -> Int64? {
        let fileManager = FileManager.default
        // The download directory is only created when the first torrent lands in it, so measure
        // the nearest ancestor that exists — same volume either way.
        var url = directory
        while !fileManager.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return nil }
            url = parent
        }

        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) else { return nil }

        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values.volumeAvailableCapacity.map(Int64.init)
    }
}
