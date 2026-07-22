import Foundation

/// Bridges LTSession's Objective-C delegate callbacks into `TorrentEngineEvent`s.
///
/// This can't just be `RealTorrentEngine` itself: `LTSession.delegate` is a plain
/// `id<LTSessionDelegate>`, which requires an actual NSObject-rooted class, and Swift
/// actors don't inherit from NSObject. The proxy only forwards into the (thread-safe,
/// Sendable) AsyncStream continuation, so no actor-isolated state is touched here.
final class LTDelegateProxy: NSObject, LTSessionDelegate {
    private let continuation: AsyncStream<TorrentEngineEvent>.Continuation

    init(continuation: AsyncStream<TorrentEngineEvent>.Continuation) {
        self.continuation = continuation
    }

    func session(_ session: LTSession, handleID: String, didReceiveMetadata metadata: LTMetadata) {
        let files = metadata.files.map { file in
            TorrentFile(index: file.fileIndex, path: file.path, size: file.size, downloadedBytes: 0, priority: .normal)
        }
        let torrentMetadata = TorrentMetadata(name: metadata.name, totalSize: metadata.totalSize, files: files)
        continuation.yield(.metadataReceived(handleID, torrentMetadata))
    }

    func session(_ session: LTSession, handleID: String, didUpdateStatus status: LTStatusSnapshot) {
        let snapshot = TorrentStatusSnapshot(
            status: Self.map(status.status),
            progress: status.progress,
            downloadSpeed: status.downloadRate,
            uploadSpeed: status.uploadRate,
            downloadedBytes: status.downloadedBytes,
            eta: status.etaSeconds >= 0 ? status.etaSeconds : nil
        )
        continuation.yield(.statusUpdate(handleID, snapshot))
    }

    func session(_ session: LTSession, handleID: String, didCompleteFileAtIndex fileIndex: Int) {
        continuation.yield(.fileCompleted(handleID, fileIndex: fileIndex))
    }

    func session(_ session: LTSession, didCompleteTorrentWithHandleID handleID: String) {
        continuation.yield(.torrentCompleted(handleID))
    }

    func session(_ session: LTSession, handleID: String, didFailWithErrorMessage message: String) {
        continuation.yield(.torrentError(handleID, .underlying(message)))
    }

    private static func map(_ status: LTTorrentStatus) -> TorrentStatus {
        switch status {
        case .queued: return .queued
        case .checking: return .checking
        case .downloadingMetadata: return .downloadingMetadata
        case .downloading: return .downloading
        case .seeding: return .seeding
        case .paused: return .paused
        case .completed: return .completed
        case .failed: return .failed
        @unknown default: return .failed
        }
    }
}
