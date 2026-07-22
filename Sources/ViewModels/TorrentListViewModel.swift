import Foundation
import Observation

@Observable
@MainActor
final class TorrentListViewModel {
    private(set) var torrents: [Torrent] = []
    var errorMessage: String?
    private let downloadManager: DownloadManager
    private var observationTask: Task<Void, Never>?

    init(downloadManager: DownloadManager) {
        self.downloadManager = downloadManager
    }

    func startObserving() async {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            let stream = self.downloadManager.snapshots
            for await snapshot in stream {
                self.torrents = snapshot
            }
        }
    }

    func torrents(for category: SidebarCategory) -> [Torrent] {
        switch category {
        case .all: return torrents
        case .downloading: return torrents.filter { $0.status == .downloading || $0.status == .downloadingMetadata || $0.status == .checking }
        case .completed: return torrents.filter { $0.status == .completed || $0.status == .seeding }
        case .failed: return torrents.filter { $0.status == .failed }
        case .settings: return []
        }
    }

    func pause(_ torrent: Torrent) {
        Task {
            do { try await downloadManager.pause(torrent.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func resume(_ torrent: Torrent) {
        Task {
            do { try await downloadManager.resume(torrent.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func remove(_ torrent: Torrent, deleteFiles: Bool) {
        Task {
            do { try await downloadManager.remove(torrent.id, deleteFiles: deleteFiles) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func torrent(withID id: TorrentHandleID?) -> Torrent? {
        guard let id else { return nil }
        return torrents.first { $0.id == id }
    }

    func setPriority(_ torrent: Torrent, priority: TorrentPriority) {
        Task { await downloadManager.setPriority(torrent.id, priority: priority) }
    }

    func setRenameRule(_ torrent: Torrent, finalName: String?) {
        Task { await downloadManager.setRenameRule(torrent.id, finalName: finalName) }
    }

    func setDestination(_ torrent: Torrent, to url: URL) {
        Task {
            do { try await downloadManager.setDestination(torrent.id, to: url) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
