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
        let label = "'\(scriptPath.path)' (tag: \(tagName), torrent: \(torrentName))"

        guard FileManager.default.fileExists(atPath: scriptPath.path) else {
            NSLog("TorrentApp: completion script not found at \(label)")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: scriptPath.path) else {
            NSLog("TorrentApp: completion script at \(label) is not executable — run `chmod +x` on it")
            return
        }

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

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        NSLog("TorrentApp: launching completion script \(label)")
        do {
            try process.run()
        } catch {
            NSLog("TorrentApp: failed to launch completion script at \(label): \(error.localizedDescription)")
            return
        }

        // Read both pipes concurrently on background queues — reading them sequentially
        // (or only after exit) can deadlock if the script writes enough output to fill
        // either pipe's kernel buffer before anyone drains it.
        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.notify(queue: .global(qos: .utility)) {
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                NSLog("TorrentApp: completion script finished successfully for \(label)")
            } else {
                NSLog("TorrentApp: completion script exited with status \(process.terminationStatus) for \(label)")
            }
            if let text = String(data: stdoutData, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSLog("TorrentApp: completion script stdout for \(label):\n\(text)")
            }
            if let text = String(data: stderrData, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSLog("TorrentApp: completion script stderr for \(label):\n\(text)")
            }
        }
    }
}
