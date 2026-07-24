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
        let fullPath = (destinationPath as NSString).appendingPathComponent(torrentName)

        let process = Process()
        process.executableURL = scriptPath
        process.arguments = [torrentName, fullPath, torrentHash, String(totalSize)]

        var environment = ProcessInfo.processInfo.environment
        environment["TORRENT_NAME"] = torrentName
        environment["TORRENT_HASH"] = torrentHash
        environment["TORRENT_PATH"] = fullPath
        environment["TORRENT_SIZE"] = String(totalSize)
        environment["TAG_NAME"] = tagName
        // Transmission-compatible names (TR_TORRENT_DIR = parent save directory,
        // TR_TORRENT_NAME = file/folder name within it), so scripts written for
        // Transmission's "run script on completion" feature work unmodified.
        environment["TR_TORRENT_DIR"] = destinationPath
        environment["TR_TORRENT_NAME"] = torrentName
        process.environment = environment

        do {
            try process.run()
        } catch {
            NSLog("TorrentApp: failed to launch completion script at \(scriptPath.path): \(error.localizedDescription)")
        }
    }
}
