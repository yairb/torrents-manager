import Foundation
import Observation

@Observable
@MainActor
final class TorrentListViewModel {
    private(set) var torrents: [Torrent] = []
    var errorMessage: String?
    private let downloadManager: DownloadManager
    private var observationTask: Task<Void, Never>?

    /// Torrents the user has asked to remove but that the engine hasn't dropped from a snapshot
    /// yet. Filtered out of the list immediately so the row disappears on the click that
    /// requested it, rather than a round trip later.
    private var pendingRemovalIDs: Set<TorrentHandleID> = []

    private let activityAssertion = ActivityAssertion(reason: "Downloading torrents")

    init(downloadManager: DownloadManager) {
        self.downloadManager = downloadManager
    }

    func startObserving() async {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            let stream = self.downloadManager.snapshots
            for await snapshot in stream {
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: [Torrent]) {
        // Anything the engine has genuinely dropped no longer needs hiding.
        if !pendingRemovalIDs.isEmpty {
            let present = Set(snapshot.map(\.id))
            pendingRemovalIDs.formIntersection(present)
        }

        // `@Observable` does no equality check of its own, so assigning an identical snapshot
        // would still invalidate every view reading `torrents` and rebuild the whole List.
        if snapshot != torrents {
            torrents = snapshot
        }

        activityAssertion.setActive(snapshot.contains { Self.isActive($0.status) })
    }

    private static func isActive(_ status: TorrentStatus) -> Bool {
        status == .downloading || status == .downloadingMetadata || status == .checking
    }

    func torrents(for category: SidebarCategory) -> [Torrent] {
        let visible = pendingRemovalIDs.isEmpty
            ? torrents
            : torrents.filter { !pendingRemovalIDs.contains($0.id) }
        switch category {
        case .all: return visible
        case .downloading: return visible.filter { Self.isActive($0.status) }
        case .completed: return visible.filter { $0.status == .completed || $0.status == .seeding }
        case .failed: return visible.filter { $0.status == .failed }
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
        pendingRemovalIDs.insert(torrent.id)
        Task {
            do {
                try await downloadManager.remove(torrent.id, deleteFiles: deleteFiles)
            } catch {
                // Put the row back — it's still there as far as the engine is concerned.
                pendingRemovalIDs.remove(torrent.id)
                errorMessage = error.localizedDescription
            }
        }
    }

    func torrent(withID id: TorrentHandleID?) -> Torrent? {
        guard let id, !pendingRemovalIDs.contains(id) else { return nil }
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

    func setTag(_ torrent: Torrent, tagID: UUID?) {
        Task { await downloadManager.setTag(torrent.id, tagID: tagID) }
    }

    func clearTag(_ tagID: UUID) {
        Task { await downloadManager.clearTag(tagID) }
    }
}
