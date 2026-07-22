import Foundation

/// Durable record of a torrent's state, independent of the transient/live fields
/// (peers, trackers, live speeds) that only make sense while the engine is running.
struct TorrentRecord: Codable, Sendable, Identifiable {
    var id: TorrentHandleID
    var displayName: String
    var originalName: String
    var status: TorrentStatus
    var progress: Double
    var totalSize: Int64
    var downloadedBytes: Int64
    var destinationDirectory: String
    var addedAt: Date
    var completedAt: Date?
    var files: [TorrentFile]
    var priority: TorrentPriority
    var postCompletionAction: PostCompletionAction
    var renameRule: RenameRule?
    var scriptConfig: ScriptConfig?
    var magnetURI: String?

    init(from torrent: Torrent, magnetURI: String? = nil) {
        id = torrent.id
        displayName = torrent.displayName
        originalName = torrent.originalName
        status = torrent.status
        progress = torrent.progress
        totalSize = torrent.totalSize
        downloadedBytes = torrent.downloadedBytes
        destinationDirectory = torrent.destinationDirectory.path
        addedAt = torrent.addedAt
        completedAt = torrent.completedAt
        files = torrent.files
        priority = torrent.priority
        postCompletionAction = torrent.postCompletionAction
        renameRule = torrent.renameRule
        scriptConfig = torrent.scriptConfig
        self.magnetURI = magnetURI
    }

    func makeTorrent() -> Torrent {
        Torrent(
            id: id,
            displayName: displayName,
            originalName: originalName,
            status: status == .completed ? .completed : .failed,
            progress: progress,
            downloadSpeed: 0,
            uploadSpeed: 0,
            eta: nil,
            totalSize: totalSize,
            downloadedBytes: downloadedBytes,
            destinationDirectory: URL(fileURLWithPath: destinationDirectory),
            addedAt: addedAt,
            completedAt: completedAt,
            files: files,
            priority: priority,
            postCompletionAction: postCompletionAction,
            renameRule: renameRule,
            scriptConfig: scriptConfig,
            peers: [],
            trackers: []
        )
    }
}

/// Persistence boundary for app state. Backed today by JSON files under Application Support;
/// designed so a future GRDB/SQLite implementation can be swapped in without touching callers.
protocol PersistenceStore: Sendable {
    func loadSettings() async -> AppSettings?
    func saveSettings(_ settings: AppSettings) async

    func fetchAllTorrents() async -> [TorrentRecord]
    func saveTorrent(_ record: TorrentRecord) async
    func deleteTorrent(_ id: TorrentHandleID) async
}
