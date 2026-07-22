import Foundation
import Observation

enum SidebarCategory: String, CaseIterable, Identifiable {
    case all = "All Torrents"
    case downloading = "Downloading"
    case completed = "Completed"
    case failed = "Failed"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .settings: return "gearshape"
        }
    }
}

@Observable
final class AppNavigationState {
    var selectedCategory: SidebarCategory = .all
    var selectedTorrentID: TorrentHandleID?

    /// The torrent whose details are open in the detail column, if any.
    /// Distinct from `selectedTorrentID` (list highlight) — the detail column
    /// only appears when this is explicitly set via a "Show Details" action,
    /// never just from selecting a row.
    var detailTorrentID: TorrentHandleID?
}
