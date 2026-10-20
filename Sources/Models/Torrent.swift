import Foundation

typealias TorrentHandleID = String

struct Torrent: Identifiable, Sendable, Equatable {
    let id: TorrentHandleID
    var displayName: String
    var originalName: String
    var status: TorrentStatus
    var progress: Double
    var downloadSpeed: Int64
    var uploadSpeed: Int64
    var eta: TimeInterval?
    var totalSize: Int64
    var downloadedBytes: Int64
    var destinationDirectory: URL
    var addedAt: Date
    var completedAt: Date?
    var files: [TorrentFile]
    var priority: TorrentPriority
    var postCompletionAction: PostCompletionAction
    var renameRule: RenameRule?
    var scriptConfig: ScriptConfig?
    var tagID: UUID?
    var peers: [PeerInfo]
    var trackers: [TrackerInfo]
}

/// `done` is terminal: the app never seeds, so a finished torrent just sits in the list,
/// uploading nothing, until the user removes it.
enum TorrentStatus: String, Sendable, Codable, CaseIterable {
    case queued, checking, downloadingMetadata, downloading, paused, done, failed

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        // Records written before seeding was dropped: finished torrents were persisted as
        // either `completed` or `seeding` depending on which one the engine last reported.
        case "completed", "seeding":
            self = .done
        default:
            guard let status = TorrentStatus(rawValue: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Unknown torrent status '\(raw)'")
                )
            }
            self = status
        }
    }
}

enum TorrentPriority: Int, Sendable, Codable, Comparable, CaseIterable {
    case low = 0, normal, high
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum PostCompletionAction: String, Sendable, Codable, CaseIterable {
    case none, moveToFolder, runScript, moveAndRunScript, stopSeeding, quitAppIfLastTorrent
}

struct TorrentFile: Identifiable, Sendable, Equatable, Codable {
    var id: Int { index }
    let index: Int
    var path: String
    var size: Int64
    var downloadedBytes: Int64
    var priority: FilePriority

    enum CodingKeys: String, CodingKey { case index, path, size, downloadedBytes, priority }
}

enum FilePriority: Int, Sendable, Codable, CaseIterable { case skip = 0, low, normal, high }

struct PeerInfo: Identifiable, Sendable, Equatable {
    var id: String { "\(ip):\(port)" }
    let ip: String
    let port: Int
    let client: String
    let downloadSpeed: Int64
    let uploadSpeed: Int64
    let progress: Double
    let flags: Set<String>
}

struct TrackerInfo: Identifiable, Sendable, Equatable {
    var id: String { url }
    let url: String
    let tier: Int
    let status: String
    let lastAnnounce: Date?
    let peersReturned: Int
}

struct RenameRule: Sendable, Codable, Equatable {
    var finalName: String
    var appliedAt: Date?
}

struct ScriptConfig: Sendable, Codable, Equatable {
    var scriptPath: URL
    var isEnabled: Bool
    var timeoutSeconds: Int
    var showExecutionLogs: Bool
}

extension Torrent {
    static func makeQueued(id: TorrentHandleID, name: String, destination: URL, totalSize: Int64) -> Torrent {
        Torrent(
            id: id,
            displayName: name,
            originalName: name,
            status: .downloadingMetadata,
            progress: 0,
            downloadSpeed: 0,
            uploadSpeed: 0,
            eta: nil,
            totalSize: totalSize,
            downloadedBytes: 0,
            destinationDirectory: destination,
            addedAt: Date(),
            completedAt: nil,
            files: [],
            priority: .normal,
            postCompletionAction: .none,
            renameRule: nil,
            scriptConfig: nil,
            tagID: nil,
            peers: [],
            trackers: []
        )
    }
}
