import AppKit

/// The "ding" played when a torrent finishes downloading.
enum CompletionSound {
    /// Name of a sound in `/System/Library/Sounds` — `NSSound(named:)` searches there after the
    /// app bundle, so this needs no bundled asset.
    private static let soundName = NSSound.Name("Glass")

    @MainActor
    static func play() {
        NSSound(named: soundName)?.play()
    }
}
