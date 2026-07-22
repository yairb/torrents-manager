import Foundation

/// Launches a tag's completion script when a torrent finishes downloading.
/// Torrent info is passed both as positional arguments and as environment variables
/// so scripts of any language/shell can pick whichever is convenient.
enum ScriptRunner {
    static func runCompletionScript(
        scriptPath: URL,
        torrentName: String,
        torrentHash: String,
        destinationPath: String,
        totalSize: Int64,
        tagName: String
    ) {
        let process = Process()
        process.executableURL = scriptPath
        process.arguments = [torrentName, destinationPath, torrentHash, String(totalSize)]

        var environment = ProcessInfo.processInfo.environment
        environment["TORRENT_NAME"] = torrentName
        environment["TORRENT_HASH"] = torrentHash
        environment["TORRENT_PATH"] = destinationPath
        environment["TORRENT_SIZE"] = String(totalSize)
        environment["TAG_NAME"] = tagName
        process.environment = environment

        do {
            try process.run()
        } catch {
            NSLog("TorrentApp: failed to launch completion script at \(scriptPath.path): \(error.localizedDescription)")
        }
    }
}
