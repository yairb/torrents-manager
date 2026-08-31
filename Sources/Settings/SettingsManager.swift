import Foundation
import Observation
import ServiceManagement

@Observable
@MainActor
final class SettingsManager {
    var settings: AppSettings

    private let persistenceStore: any PersistenceStore
    private let downloadManager: DownloadManager

    init(persistenceStore: any PersistenceStore, downloadManager: DownloadManager, initialSettings: AppSettings = .default) {
        self.persistenceStore = persistenceStore
        self.downloadManager = downloadManager
        self.settings = initialSettings
    }

    /// Loads persisted settings (if any) and applies them to the download manager.
    /// Call once at app launch, before `DownloadManager.start()`.
    func reload() async {
        settings = await persistenceStore.loadSettings() ?? .default
        await apply(settings)
    }

    /// Persists the current settings and applies them live.
    func save() {
        let current = settings
        Task {
            await persistenceStore.saveSettings(current)
            await apply(current)
        }
    }

    private func apply(_ settings: AppSettings) async {
        await downloadManager.updateMaxParallelDownloads(settings.maxParallelDownloads)
        await downloadManager.updateGlobalDownloadLimit(settings.globalDownloadLimitBytesPerSec)
        await downloadManager.updateGlobalUploadLimit(settings.globalUploadLimitBytesPerSec)
        await downloadManager.updateTags(settings.tags)
        await downloadManager.updateCompletionSoundEnabled(settings.completionSoundEnabled)
        try? applyLoginItem(enabled: settings.launchAtLogin)
    }

    private func applyLoginItem(enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
