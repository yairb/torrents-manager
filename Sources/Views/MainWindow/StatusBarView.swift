import SwiftUI

/// Thin strip across the bottom of the window reporting how much room is left for downloads,
/// i.e. on the volume holding the default download directory.
struct StatusBarView: View {
    @Environment(SettingsManager.self) private var settingsManager

    @State private var availableBytes: Int64?

    private var downloadDirectory: URL {
        settingsManager.settings.defaultDownloadDirectory
    }

    var body: some View {
        HStack(spacing: 5) {
            Spacer()
            Image(systemName: "internaldrive")
            Text(label)
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
        // Re-measured on a loop rather than once: the number drifts the whole time torrents are
        // writing, and nothing else in the app is in a position to say when it changed.
        .task(id: downloadDirectory) {
            while !Task.isCancelled {
                let directory = downloadDirectory
                availableBytes = await Task.detached { Self.availableCapacity(for: directory) }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var label: String {
        guard let availableBytes else { return "— free" }
        return Self.byteFormatter.string(fromByteCount: availableBytes) + " free"
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
