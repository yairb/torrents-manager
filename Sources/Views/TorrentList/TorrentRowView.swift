import SwiftUI

struct TorrentRowView: View {
    let torrent: Torrent
    var isSelected: Bool = false
    var onShowDetails: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(torrent.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                StatusBadge(status: torrent.status)
                if let onShowDetails {
                    Button(action: onShowDetails) {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Show Details")
                }
            }

            ProgressView(value: torrent.progress)
                .progressViewStyle(.linear)

            HStack(spacing: 16) {
                Label(formatSpeed(torrent.downloadSpeed), systemImage: "arrow.down")
                    .foregroundStyle(.blue)
                Label(formatSpeed(torrent.uploadSpeed), systemImage: "arrow.up")
                    .foregroundStyle(.green)
                if let eta = torrent.eta {
                    Label(formatETA(eta), systemImage: "clock")
                }
                Spacer()
                Text(torrent.destinationDirectory.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
    }

    private func formatSpeed(_ bytesPerSecond: Int64) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .binary) + "/s"
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "—"
    }
}

private struct StatusBadge: View {
    let status: TorrentStatus

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .queued: return "Queued"
        case .checking: return "Checking"
        case .downloadingMetadata: return "Fetching Info"
        case .downloading: return "Downloading"
        case .seeding: return "Seeding"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private var color: Color {
        switch status {
        case .queued, .checking, .downloadingMetadata: return .gray
        case .downloading: return .blue
        case .seeding, .completed: return .green
        case .paused: return .orange
        case .failed: return .red
        }
    }
}
