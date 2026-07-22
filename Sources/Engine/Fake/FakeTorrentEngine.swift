import Foundation

/// In-memory simulated engine used until the real libtorrent-rasterbar bridge is wired in.
/// Conforms to the same `TorrentEngine` protocol the real engine will, so nothing above this
/// layer (DownloadManager, ViewModels, Views) needs to change when it's swapped out.
actor FakeTorrentEngine: TorrentEngine {
    private struct SimState {
        var metadata: TorrentMetadata
        var progress: Double = 0
        var isPaused: Bool = false
        var downloadSpeed: Int64 = 0
    }

    private var torrents: [TorrentHandleID: SimState] = [:]
    private var tickTask: Task<Void, Never>?
    private var tickCount = 0
    private let continuation: AsyncStream<TorrentEngineEvent>.Continuation
    nonisolated let events: AsyncStream<TorrentEngineEvent>

    init() {
        var cont: AsyncStream<TorrentEngineEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func start() async throws {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
    }

    func shutdown() async {
        tickTask?.cancel()
        tickTask = nil
        continuation.finish()
    }

    func addTorrent(magnetURI: String, options: AddTorrentOptions) async throws -> TorrentHandleID {
        guard magnetURI.hasPrefix("magnet:?") else {
            throw EngineError.invalidMagnetURI(magnetURI)
        }
        let name = extractDisplayName(fromMagnet: magnetURI) ?? "Unknown Torrent"
        let id = extractInfoHash(fromMagnet: magnetURI) ?? UUID().uuidString
        return try await registerSimulatedTorrent(id: id, name: name, options: options)
    }

    func addTorrent(fileData: Data, options: AddTorrentOptions) async throws -> TorrentHandleID {
        guard !fileData.isEmpty else { throw EngineError.invalidTorrentFile }
        let id = UUID().uuidString
        let name = "Imported Torrent \(id.prefix(6))"
        return try await registerSimulatedTorrent(id: id, name: name, options: options)
    }

    private func registerSimulatedTorrent(id: TorrentHandleID, name: String, options: AddTorrentOptions) async throws -> TorrentHandleID {
        let totalSize = Int64.random(in: 200_000_000...4_000_000_000)
        let fileCount = Int.random(in: 1...5)
        let files = (0..<fileCount).map { index in
            TorrentFile(index: index, path: "\(name)/file\(index).bin",
                        size: totalSize / Int64(fileCount), downloadedBytes: 0, priority: .normal)
        }
        let metadata = TorrentMetadata(name: name, totalSize: totalSize, files: files, rawData: nil)
        torrents[id] = SimState(metadata: metadata, isPaused: options.startPaused)

        // Simulate the brief metadata-fetch delay a real magnet link has.
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            continuation.yield(.metadataReceived(id, metadata))
        }
        return id
    }

    func pause(_ id: TorrentHandleID) async throws {
        guard torrents[id] != nil else { throw EngineError.torrentNotFound(id) }
        torrents[id]?.isPaused = true
    }

    func resume(_ id: TorrentHandleID) async throws {
        guard torrents[id] != nil else { throw EngineError.torrentNotFound(id) }
        torrents[id]?.isPaused = false
    }

    func remove(_ id: TorrentHandleID, deleteFiles: Bool) async throws {
        torrents.removeValue(forKey: id)
    }

    func setFilePriority(_ id: TorrentHandleID, fileIndex: Int, priority: FilePriority) async throws {}

    func renameFile(_ id: TorrentHandleID, fileIndex: Int, newName: String) async throws {
        guard torrents[id] != nil else { throw EngineError.torrentNotFound(id) }
    }

    func moveStorage(_ id: TorrentHandleID, to newPath: URL) async throws {}

    func setGlobalDownloadLimit(bytesPerSecond: Int?) async {}
    func setGlobalUploadLimit(bytesPerSecond: Int?) async {}
    func setMaxActiveDownloads(_ count: Int) async {}

    private func tick() async {
        tickCount += 1
        for id in Array(torrents.keys) {
            guard var state = torrents[id], !state.isPaused, state.progress < 1.0 else { continue }
            let increment = Double.random(in: 0.01...0.06)
            state.progress = min(1.0, state.progress + increment)
            state.downloadSpeed = Int64.random(in: 500_000...8_000_000)
            torrents[id] = state

            let downloaded = Int64(Double(state.metadata.totalSize) * state.progress)
            let remaining = state.metadata.totalSize - downloaded
            let eta: TimeInterval? = state.downloadSpeed > 0 ? Double(remaining) / Double(state.downloadSpeed) : nil

            let snapshot = TorrentStatusSnapshot(
                status: state.progress >= 1.0 ? .completed : .downloading,
                progress: state.progress,
                downloadSpeed: state.progress >= 1.0 ? 0 : state.downloadSpeed,
                uploadSpeed: Int64.random(in: 0...200_000),
                downloadedBytes: downloaded,
                eta: state.progress >= 1.0 ? nil : eta
            )
            continuation.yield(.statusUpdate(id, snapshot))
            continuation.yield(.peerListUpdate(id, randomPeers()))
            if tickCount % 5 == 0 {
                continuation.yield(.trackerListUpdate(id, randomTrackers()))
            }
            if state.progress >= 1.0 {
                continuation.yield(.torrentCompleted(id))
            }
        }
    }

    private func randomPeers() -> [PeerInfo] {
        let clients = ["qBittorrent/4.6", "Transmission/4.0", "libtorrent/2.0", "Deluge/2.1"]
        return (0..<Int.random(in: 3...8)).map { _ in
            PeerInfo(
                ip: "\(Int.random(in: 1...223)).\(Int.random(in: 0...255)).\(Int.random(in: 0...255)).\(Int.random(in: 1...254))",
                port: Int.random(in: 1024...65535),
                client: clients.randomElement()!,
                downloadSpeed: Int64.random(in: 0...2_000_000),
                uploadSpeed: Int64.random(in: 0...500_000),
                progress: Double.random(in: 0...1),
                flags: []
            )
        }
    }

    private func randomTrackers() -> [TrackerInfo] {
        let urls = [
            "udp://tracker.opentrackr.org:1337/announce",
            "udp://tracker.openbittorrent.com:6969/announce",
            "udp://exodus.desync.com:6969/announce",
        ]
        return urls.enumerated().map { index, url in
            TrackerInfo(url: url, tier: index, status: "Working", lastAnnounce: Date(), peersReturned: Int.random(in: 5...40))
        }
    }

    private func extractDisplayName(fromMagnet uri: String) -> String? {
        guard let components = URLComponents(string: uri) else { return nil }
        let dn = components.queryItems?.first(where: { $0.name == "dn" })?.value
        return dn?.removingPercentEncoding
    }

    private func extractInfoHash(fromMagnet uri: String) -> String? {
        guard let components = URLComponents(string: uri) else { return nil }
        guard let xt = components.queryItems?.first(where: { $0.name == "xt" })?.value else { return nil }
        return xt.replacingOccurrences(of: "urn:btih:", with: "").lowercased()
    }
}
