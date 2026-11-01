import Foundation
import Observation

@Observable
@MainActor
final class TorrentListViewModel {
    private(set) var torrents: [Torrent] = []
    var errorMessage: String?

    /// Bumped whenever a torrent joins or leaves the list, or any torrent changes status —
    /// added, removed, started, promoted out of the queue, paused, finished. Never for a mere
    /// progress tick.
    ///
    /// These are the moments the amount of free disk space is about to move, or has just
    /// finished moving, so the free-space bar re-measures on each of them. Snapshots otherwise
    /// arrive several times a second carrying nothing but new speeds and byte counts, and
    /// re-measuring on those would be pointless work.
    private(set) var diskActivityRevision: Int = 0
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

    /// Idempotent, and deliberately never cancels a live observation.
    ///
    /// SwiftUI re-runs the `.task` that calls this every time it re-creates the view. Tearing the
    /// observation down and standing it back up on each of those used to kill the snapshot stream
    /// outright — cancelling the task iterating an `AsyncStream` terminates it for good — which
    /// left the list showing whatever it happened to hold at that moment until the app relaunched.
    func startObserving() async {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.downloadManager.snapshots
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

        // Compared as ordered lists rather than sets: the snapshot is always sorted by
        // `addedAt`, so an add and a remove landing in the same frame still shows up here.
        // `lazy` keeps this to a walk of the two arrays — it runs on every snapshot.
        if !snapshot.lazy.map(\.id).elementsEqual(torrents.lazy.map(\.id))
            || !snapshot.lazy.map(\.status).elementsEqual(torrents.lazy.map(\.status)) {
            diskActivityRevision &+= 1
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
        case .done: return visible.filter { $0.status == .done }
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

    /// Drops every finished torrent from the list, leaving the downloaded files in place.
    func removeDoneTorrents() {
        for torrent in torrents where torrent.status == .done && !pendingRemovalIDs.contains(torrent.id) {
            remove(torrent, deleteFiles: false)
        }
    }

    /// Bytes still to be written to disk by everything in the list: what the free-space bar
    /// subtracts to project where the volume lands once the queue has drained.
    ///
    /// Counts torrents that are already downloading as well as queued ones. libtorrent writes
    /// sparse files, so a torrent that has started has only taken up what it has actually
    /// fetched so far — its remaining bytes are every bit as unclaimed as a queued torrent's.
    /// A queued magnet that hasn't pulled its metadata yet reports a total size of 0 and so
    /// contributes nothing until it knows how big it is.
    var pendingDownloadBytes: Int64 {
        torrents.reduce(into: Int64(0)) { total, torrent in
            guard Self.willStillWriteToDisk(torrent), !pendingRemovalIDs.contains(torrent.id) else { return }
            total += max(0, torrent.totalSize - torrent.downloadedBytes)
        }
    }

    /// Whether any unfinished torrent has yet to learn how big it is, which happens between
    /// adding a magnet link and its metadata arriving. Those contribute nothing to
    /// `pendingDownloadBytes` however large they turn out to be, so a projection made while one
    /// is outstanding is an upper bound on the free space left, not a figure.
    var hasUnsizedTorrents: Bool {
        torrents.contains { torrent in
            Self.willStillWriteToDisk(torrent)
                && !pendingRemovalIDs.contains(torrent.id)
                && torrent.totalSize == 0
        }
    }

    private static func willStillWriteToDisk(_ torrent: Torrent) -> Bool {
        torrent.status != .done && torrent.status != .failed
    }

    var hasDoneTorrents: Bool {
        torrents.contains { $0.status == .done && !pendingRemovalIDs.contains($0.id) }
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
