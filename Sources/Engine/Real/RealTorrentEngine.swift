import Foundation

/// `TorrentEngine` implementation backed by libtorrent-rasterbar via the `LTSession`
/// Objective-C++ bridge (see Sources/Bridge). Owns the session's lifetime and translates
/// its delegate callbacks (via `LTDelegateProxy`) into `TorrentEngineEvent`s.
actor RealTorrentEngine: TorrentEngine {
    private let session: LTSession
    private var delegateProxy: LTDelegateProxy?
    private let continuation: AsyncStream<TorrentEngineEvent>.Continuation
    nonisolated let events: AsyncStream<TorrentEngineEvent>

    init(sessionDirectory: URL) {
        var cont: AsyncStream<TorrentEngineEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
        self.session = LTSession(sessionDirectory: sessionDirectory.path)
    }

    func start() async throws {
        let proxy = LTDelegateProxy(continuation: continuation)
        delegateProxy = proxy
        session.delegate = proxy
        do {
            try session.start()
        } catch {
            throw EngineError.underlying(error.localizedDescription)
        }
    }

    func shutdown() async {
        session.shutdown()
        session.delegate = nil
        delegateProxy = nil
        continuation.finish()
    }

    @discardableResult
    func addTorrent(magnetURI: String, options: AddTorrentOptions) async throws -> TorrentHandleID {
        guard magnetURI.hasPrefix("magnet:") else {
            throw EngineError.invalidMagnetURI(magnetURI)
        }
        try prepareDestination(options.destinationDirectory)
        do {
            return try session.addTorrent(
                magnetURI: magnetURI,
                destinationPath: options.destinationDirectory.path,
                startPaused: options.startPaused
            )
        } catch {
            throw EngineError.underlying(error.localizedDescription)
        }
    }

    @discardableResult
    func addTorrent(fileData: Data, options: AddTorrentOptions) async throws -> TorrentHandleID {
        guard !fileData.isEmpty else { throw EngineError.invalidTorrentFile }
        try prepareDestination(options.destinationDirectory)
        do {
            return try session.addTorrent(
                fileData: fileData,
                destinationPath: options.destinationDirectory.path,
                startPaused: options.startPaused
            )
        } catch {
            throw EngineError.invalidTorrentFile
        }
    }

    func pause(_ id: TorrentHandleID) async throws {
        try callThrowing(id) { try session.pauseHandle(id) }
    }

    func resume(_ id: TorrentHandleID) async throws {
        try callThrowing(id) { try session.resumeHandle(id) }
    }

    func remove(_ id: TorrentHandleID, deleteFiles: Bool) async throws {
        try callThrowing(id) { try session.removeHandle(id, deleteFiles: deleteFiles) }
    }

    func setFilePriority(_ id: TorrentHandleID, fileIndex: Int, priority: FilePriority) async throws {
        try callThrowing(id) {
            try session.setFilePriority(forHandle: id, fileIndex: fileIndex, priority: Self.ltPriority(for: priority))
        }
    }

    func renameFile(_ id: TorrentHandleID, fileIndex: Int, newName: String) async throws {
        try callThrowing(id) { try session.renameFile(forHandle: id, fileIndex: fileIndex, newName: newName) }
    }

    func moveStorage(_ id: TorrentHandleID, to newPath: URL) async throws {
        try prepareDestination(newPath)
        try callThrowing(id) { try session.moveStorage(forHandle: id, newPath: newPath.path) }
    }

    func setGlobalDownloadLimit(bytesPerSecond: Int?) async {
        session.setGlobalDownloadLimit(Int64(bytesPerSecond ?? 0))
    }

    func setGlobalUploadLimit(bytesPerSecond: Int?) async {
        session.setGlobalUploadLimit(Int64(bytesPerSecond ?? 0))
    }

    func setMaxActiveDownloads(_ count: Int) async {
        session.setMaxActiveDownloads(count)
    }

    private func prepareDestination(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func callThrowing(_ id: TorrentHandleID, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            let description = error.localizedDescription
            if description.contains("Unknown torrent handle") {
                throw EngineError.torrentNotFound(id)
            }
            throw EngineError.underlying(description)
        }
    }

    private static func ltPriority(for priority: FilePriority) -> Int {
        switch priority {
        case .skip: return 0
        case .low: return 1
        case .normal: return 4
        case .high: return 7
        }
    }
}
