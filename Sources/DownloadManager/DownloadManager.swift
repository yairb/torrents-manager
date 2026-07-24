import Foundation

actor DownloadManager {
    private let engine: any TorrentEngine
    private let persistenceStore: any PersistenceStore
    private var torrents: [TorrentHandleID: Torrent] = [:]
    private var magnetURIs: [TorrentHandleID: String] = [:]
    private var torrentFileBlobs: [TorrentHandleID: Data] = [:]
    private var queuedIDs: Set<TorrentHandleID> = []
    private var pausedIDs: Set<TorrentHandleID> = []
    private var maxParallelDownloads: Int
    private var tags: [Tag] = []
    private var eventConsumerTask: Task<Void, Never>?

    private let continuation: AsyncStream<[Torrent]>.Continuation
    nonisolated let snapshots: AsyncStream<[Torrent]>

    init(engine: any TorrentEngine, persistenceStore: any PersistenceStore = JSONFilePersistenceStore(), maxParallelDownloads: Int = 3) {
        self.engine = engine
        self.persistenceStore = persistenceStore
        self.maxParallelDownloads = maxParallelDownloads
        var cont: AsyncStream<[Torrent]>.Continuation!
        self.snapshots = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func start() async throws {
        try await engine.start()
        eventConsumerTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.engine.events {
                await self.handle(event)
            }
        }
        for record in await persistenceStore.fetchAllTorrents() {
            await reattach(record)
        }
        promoteQueuedTorrentsIfNeeded()
        publish()
    }

    /// Restores a persisted torrent across an app restart. Torrents that were still active
    /// (downloading, paused, queued, checking, seeding) need a live engine handle again —
    /// re-adding via the stored magnet URI or raw torrent data reuses the same info-hash-derived
    /// ID, so it reattaches to whatever data libtorrent finds on disk rather than starting over.
    /// Torrents with no way to reconstruct their metadata (or that fail to re-add) fall back to
    /// `.failed` since there's nothing left to resume.
    private func reattach(_ record: TorrentRecord) async {
        guard record.status != .completed, record.status != .failed else {
            torrents[record.id] = record.makeTorrent()
            return
        }

        let destination = URL(fileURLWithPath: record.destinationDirectory)
        let shouldStartPaused = record.status == .paused || record.status == .queued
        let options = AddTorrentOptions(destinationDirectory: destination, startPaused: shouldStartPaused)

        do {
            let id: TorrentHandleID
            if let fileData = record.torrentFileData {
                id = try await engine.addTorrent(fileData: fileData, options: options)
            } else if let magnetURI = record.magnetURI {
                id = try await engine.addTorrent(magnetURI: magnetURI, options: options)
            } else {
                var torrent = record.makeTorrent()
                torrent.status = .failed
                torrents[record.id] = torrent
                return
            }

            if id != record.id {
                Task { await persistenceStore.deleteTorrent(record.id) }
            }

            var reattachedRecord = record
            reattachedRecord.id = id
            var torrent = reattachedRecord.makeTorrent()
            switch record.status {
            case .queued:
                torrent.status = .queued
                queuedIDs.insert(id)
            case .paused:
                torrent.status = .paused
                pausedIDs.insert(id)
            default:
                torrent.status = record.status
            }

            torrents[id] = torrent
            magnetURIs[id] = record.magnetURI
            if let fileData = record.torrentFileData { torrentFileBlobs[id] = fileData }
            persistTorrent(id)
        } catch {
            var torrent = record.makeTorrent()
            torrent.status = .failed
            torrents[record.id] = torrent
        }
    }

    func shutdown() async {
        eventConsumerTask?.cancel()
        await engine.shutdown()
    }

    @discardableResult
    func addTorrent(magnetURI: String, destination: URL) async throws -> TorrentHandleID {
        let shouldQueue = activeCount() >= maxParallelDownloads
        let options = AddTorrentOptions(destinationDirectory: destination, startPaused: shouldQueue)
        let id = try await engine.addTorrent(magnetURI: magnetURI, options: options)
        // The same info-hash can come back from the engine more than once (duplicate
        // submission, re-adding an already-known torrent, etc). libtorrent just returns
        // the existing handle in that case, and re-registering would wipe out whatever
        // metadata/progress that torrent already has, resetting its display back to
        // "Fetching metadata…" forever (the underlying one-shot metadata event won't fire again).
        guard torrents[id] == nil else { return id }
        register(id: id, destination: destination, shouldQueue: shouldQueue, magnetURI: magnetURI)
        return id
    }

    @discardableResult
    func addTorrent(fileData: Data, destination: URL) async throws -> TorrentHandleID {
        let shouldQueue = activeCount() >= maxParallelDownloads
        let options = AddTorrentOptions(destinationDirectory: destination, startPaused: shouldQueue)
        let id = try await engine.addTorrent(fileData: fileData, options: options)
        guard torrents[id] == nil else { return id }
        register(id: id, destination: destination, shouldQueue: shouldQueue, magnetURI: nil)
        return id
    }

    private func register(id: TorrentHandleID, destination: URL, shouldQueue: Bool, magnetURI: String?) {
        var torrent = Torrent.makeQueued(id: id, name: "Fetching metadata…", destination: destination, totalSize: 0)
        if shouldQueue {
            torrent.status = .queued
            queuedIDs.insert(id)
        }
        torrents[id] = torrent
        magnetURIs[id] = magnetURI
        persistTorrent(id)
        publish()
    }

    func pause(_ id: TorrentHandleID) async throws {
        try await engine.pause(id)
        queuedIDs.remove(id)
        pausedIDs.insert(id)
        torrents[id]?.status = .paused
        persistTorrent(id)
        promoteQueuedTorrentsIfNeeded()
        publish()
    }

    func resume(_ id: TorrentHandleID) async throws {
        try await engine.resume(id)
        queuedIDs.remove(id)
        pausedIDs.remove(id)
        torrents[id]?.status = .downloading
        persistTorrent(id)
        publish()
    }

    func remove(_ id: TorrentHandleID, deleteFiles: Bool) async throws {
        do {
            try await engine.remove(id, deleteFiles: deleteFiles)
        } catch EngineError.torrentNotFound {
            // Torrents persisted as terminal (failed/completed) before a fix, or that
            // otherwise never got a live engine handle, have nothing to remove from the
            // engine — fall through and just clean up local/persisted state.
        }
        torrents.removeValue(forKey: id)
        magnetURIs.removeValue(forKey: id)
        torrentFileBlobs.removeValue(forKey: id)
        queuedIDs.remove(id)
        pausedIDs.remove(id)
        Task { await persistenceStore.deleteTorrent(id) }
        promoteQueuedTorrentsIfNeeded()
        publish()
    }

    func setPriority(_ id: TorrentHandleID, priority: TorrentPriority) {
        torrents[id]?.priority = priority
        persistTorrent(id)
        publish()
    }

    func setRenameRule(_ id: TorrentHandleID, finalName: String?) {
        guard var torrent = torrents[id] else { return }
        if let finalName, !finalName.isEmpty {
            torrent.renameRule = RenameRule(finalName: finalName, appliedAt: torrent.status == .completed ? Date() : nil)
            torrent.displayName = finalName
        } else {
            torrent.renameRule = nil
            torrent.displayName = torrent.originalName
        }
        torrents[id] = torrent
        persistTorrent(id)
        publish()
    }

    func setDestination(_ id: TorrentHandleID, to newURL: URL) async throws {
        try await engine.moveStorage(id, to: newURL)
        torrents[id]?.destinationDirectory = newURL
        persistTorrent(id)
        publish()
    }

    func setTag(_ id: TorrentHandleID, tagID: UUID?) {
        torrents[id]?.tagID = tagID
        persistTorrent(id)
        publish()
    }

    /// Clears a tag from any torrent that still references it, e.g. after the tag itself was deleted.
    func clearTag(_ tagID: UUID) {
        for id in torrents.keys where torrents[id]?.tagID == tagID {
            torrents[id]?.tagID = nil
            persistTorrent(id)
        }
        publish()
    }

    func updateTags(_ tags: [Tag]) {
        self.tags = tags
    }

    func updateMaxParallelDownloads(_ count: Int) async {
        maxParallelDownloads = count
        await engine.setMaxActiveDownloads(count)
        promoteQueuedTorrentsIfNeeded()
        publish()
    }

    func updateGlobalDownloadLimit(_ bytesPerSecond: Int?) async {
        await engine.setGlobalDownloadLimit(bytesPerSecond: bytesPerSecond)
    }

    func updateGlobalUploadLimit(_ bytesPerSecond: Int?) async {
        await engine.setGlobalUploadLimit(bytesPerSecond: bytesPerSecond)
    }

    private func handle(_ event: TorrentEngineEvent) async {
        switch event {
        case .metadataReceived(let id, let metadata):
            guard var torrent = torrents[id] else { break }
            torrent.originalName = metadata.name
            torrent.displayName = torrent.renameRule?.finalName ?? metadata.name
            torrent.totalSize = metadata.totalSize
            torrent.files = metadata.files
            if !queuedIDs.contains(id) && !pausedIDs.contains(id) {
                torrent.status = .downloading
            }
            torrents[id] = torrent
            if let rawData = metadata.rawData {
                torrentFileBlobs[id] = rawData
            }
            persistTorrent(id)

        case .statusUpdate(let id, let snapshot):
            torrents[id]?.status = snapshot.status
            torrents[id]?.progress = snapshot.progress
            torrents[id]?.downloadSpeed = snapshot.downloadSpeed
            torrents[id]?.uploadSpeed = snapshot.uploadSpeed
            torrents[id]?.downloadedBytes = snapshot.downloadedBytes
            torrents[id]?.eta = snapshot.eta

        case .fileCompleted(let id, let fileIndex):
            guard var torrent = torrents[id], torrent.files.indices.contains(fileIndex) else { break }
            torrent.files[fileIndex].downloadedBytes = torrent.files[fileIndex].size
            torrents[id] = torrent

        case .torrentCompleted(let id):
            torrents[id]?.status = .completed
            torrents[id]?.completedAt = Date()
            persistTorrent(id)
            promoteQueuedTorrentsIfNeeded()
            runCompletionScriptIfNeeded(for: id)

        case .torrentError(let id, _):
            torrents[id]?.status = .failed
            persistTorrent(id)
            promoteQueuedTorrentsIfNeeded()

        case .peerListUpdate(let id, let peers):
            torrents[id]?.peers = peers

        case .trackerListUpdate(let id, let trackers):
            torrents[id]?.trackers = trackers
        }
        publish()
    }

    private func activeCount() -> Int {
        torrents.values.filter {
            $0.status == .downloading || $0.status == .downloadingMetadata || $0.status == .checking
        }.count
    }

    private func promoteQueuedTorrentsIfNeeded() {
        let freeSlots = maxParallelDownloads - activeCount()
        guard freeSlots > 0 else { return }
        let candidates = torrents.values
            .filter { queuedIDs.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.priority == rhs.priority ? lhs.addedAt < rhs.addedAt : lhs.priority > rhs.priority
            }
            .prefix(freeSlots)

        guard !candidates.isEmpty else { return }
        for torrent in candidates {
            queuedIDs.remove(torrent.id)
            torrents[torrent.id]?.status = .downloading
            let engine = self.engine
            Task { try? await engine.resume(torrent.id) }
        }
    }

    private func runCompletionScriptIfNeeded(for id: TorrentHandleID) {
        guard let torrent = torrents[id] else { return }
        guard let tagID = torrent.tagID else { return }
        guard let tag = tags.first(where: { $0.id == tagID }) else {
            NSLog("TorrentApp: torrent '\(torrent.originalName)' finished but its assigned tag no longer exists — skipping completion script")
            return
        }
        guard let scriptPath = tag.scriptPath else { return }
        ScriptRunner.runCompletionScript(
            scriptPath: scriptPath,
            // Rename rules only relabel `displayName` in the UI/persistence — they're never
            // propagated to the engine, so the file/folder on disk is still named per
            // `originalName`. Scripts need the real on-disk name to find the content.
            torrentName: torrent.originalName,
            torrentHash: torrent.id,
            destinationPath: torrent.destinationDirectory.path,
            totalSize: torrent.totalSize,
            tagName: tag.name
        )
    }

    private func persistTorrent(_ id: TorrentHandleID) {
        guard let torrent = torrents[id] else { return }
        let record = TorrentRecord(from: torrent, magnetURI: magnetURIs[id], torrentFileData: torrentFileBlobs[id])
        let store = persistenceStore
        Task { await store.saveTorrent(record) }
    }

    private func publish() {
        continuation.yield(Array(torrents.values).sorted { $0.addedAt > $1.addedAt })
    }
}
