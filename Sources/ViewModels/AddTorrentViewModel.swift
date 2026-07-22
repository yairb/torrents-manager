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
        guard uri.hasPrefix("magnet:?") else {
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
        let destination = defaultDestination
        for link in links where link.hasPrefix("magnet:?") {
            Task { try? await downloadManager.addTorrent(magnetURI: link, destination: destination) }
        }
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
