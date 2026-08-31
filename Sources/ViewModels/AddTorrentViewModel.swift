import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AddTorrentViewModel {
    var isShowingAddMagnetSheet = false
    var magnetURIInput = ""
    var errorMessage: String?

    private let downloadManager: DownloadManager
    private let settingsManager: SettingsManager
    private var isSubmitting = false

    init(downloadManager: DownloadManager, settingsManager: SettingsManager) {
        self.downloadManager = downloadManager
        self.settingsManager = settingsManager
    }

    var defaultDestination: URL {
        settingsManager.settings.defaultDownloadDirectory
    }

    func submitMagnetLink() {
        // The Add button's default-action shortcut and the text field's onSubmit
        // both fire on Return, which would otherwise add the same magnet twice.
        guard !isSubmitting else { return }
        let uri = magnetURIInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard uri.hasPrefix("magnet:") else {
            errorMessage = "That doesn't look like a valid magnet link."
            return
        }
        let destination = defaultDestination
        isSubmitting = true
        Task {
            do {
                try await downloadManager.addTorrent(magnetURI: uri, destination: destination)
                await MainActor.run {
                    self.magnetURIInput = ""
                    self.errorMessage = nil
                    self.isShowingAddMagnetSheet = false
                    self.isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSubmitting = false
                }
            }
        }
    }

    func handleDroppedMagnetLinks(_ links: [String]) {
        addMagnets(links)
    }

    /// Adds every magnet URI in `uris` to the default download directory. Non-magnet entries are
    /// ignored, so callers can pass raw text without pre-filtering.
    func addMagnets(_ uris: [String]) {
        let destination = defaultDestination
        for uri in Self.magnets(in: uris) {
            Task { try? await downloadManager.addTorrent(magnetURI: uri, destination: destination) }
        }
    }

    /// Adds any magnet links found on the general pasteboard. Returns `false` when the clipboard
    /// holds nothing usable, so a keyboard-shortcut caller can fall back to a normal paste.
    @discardableResult
    func addMagnetsFromClipboard() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string) else { return false }
        let uris = Self.magnets(in: text.components(separatedBy: .newlines))
        guard !uris.isEmpty else { return false }
        addMagnets(uris)
        return true
    }

    private static func magnets(in candidates: [String]) -> [String] {
        candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("magnet:") }
    }

    func submitTorrentFile(at url: URL) {
        let destination = defaultDestination
        Task {
            do {
                let data = try Data(contentsOf: url)
                try await downloadManager.addTorrent(fileData: data, destination: destination)
                await MainActor.run {
                    self.errorMessage = nil
                    self.isShowingAddMagnetSheet = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func handleDroppedTorrentFiles(_ urls: [URL]) {
        let destination = defaultDestination
        for url in urls where url.pathExtension.lowercased() == "torrent" {
            Task {
                guard let data = try? Data(contentsOf: url) else { return }
                _ = try? await downloadManager.addTorrent(fileData: data, destination: destination)
            }
        }
    }
}
