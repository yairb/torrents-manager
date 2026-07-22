import Foundation

/// Abstraction over the underlying torrent engine (libtorrent-rasterbar, eventually).
/// Nothing outside `Sources/Engine` should ever depend on the concrete implementation.
protocol TorrentEngine: Actor {
    func start() async throws
    func shutdown() async

    @discardableResult
    func addTorrent(magnetURI: String, options: AddTorrentOptions) async throws -> TorrentHandleID

    @discardableResult
    func addTorrent(fileData: Data, options: AddTorrentOptions) async throws -> TorrentHandleID

    func pause(_ id: TorrentHandleID) async throws
    func resume(_ id: TorrentHandleID) async throws
    func remove(_ id: TorrentHandleID, deleteFiles: Bool) async throws

    func setFilePriority(_ id: TorrentHandleID, fileIndex: Int, priority: FilePriority) async throws
    func renameFile(_ id: TorrentHandleID, fileIndex: Int, newName: String) async throws
    func moveStorage(_ id: TorrentHandleID, to newPath: URL) async throws

    func setGlobalDownloadLimit(bytesPerSecond: Int?) async
    func setGlobalUploadLimit(bytesPerSecond: Int?) async
    func setMaxActiveDownloads(_ count: Int) async

    /// Continuous stream of engine events. Consumed by DownloadManager only.
    var events: AsyncStream<TorrentEngineEvent> { get }
}

struct AddTorrentOptions: Sendable {
    var destinationDirectory: URL
    var startPaused: Bool = false
    var sequentialDownload: Bool = false
}

enum EngineError: Error, Sendable, LocalizedError {
    case torrentNotFound(TorrentHandleID)
    case invalidMagnetURI(String)
    case invalidTorrentFile
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .torrentNotFound(let id): return "Torrent not found: \(id)"
        case .invalidMagnetURI(let uri): return "Invalid magnet URI: \(uri)"
        case .invalidTorrentFile: return "Invalid or corrupt .torrent file"
        case .underlying(let message): return message
        }
    }
}

struct TorrentMetadata: Sendable {
    let name: String
    let totalSize: Int64
    let files: [TorrentFile]
}

struct TorrentStatusSnapshot: Sendable {
    var status: TorrentStatus
    var progress: Double
    var downloadSpeed: Int64
    var uploadSpeed: Int64
    var downloadedBytes: Int64
    var eta: TimeInterval?
}

enum TorrentEngineEvent: Sendable {
    case metadataReceived(TorrentHandleID, TorrentMetadata)
    case statusUpdate(TorrentHandleID, TorrentStatusSnapshot)
    case fileCompleted(TorrentHandleID, fileIndex: Int)
    case torrentCompleted(TorrentHandleID)
    case torrentError(TorrentHandleID, EngineError)
    case peerListUpdate(TorrentHandleID, [PeerInfo])
    case trackerListUpdate(TorrentHandleID, [TrackerInfo])

    var torrentID: TorrentHandleID {
        switch self {
        case .metadataReceived(let id, _), .statusUpdate(let id, _), .fileCompleted(let id, _),
             .torrentCompleted(let id), .torrentError(let id, _), .peerListUpdate(let id, _),
             .trackerListUpdate(let id, _):
            return id
        }
    }
}
