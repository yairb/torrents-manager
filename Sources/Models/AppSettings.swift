import Foundation

struct AppSettings: Sendable, Codable, Equatable {
    var defaultDownloadDirectory: URL
    var maxParallelDownloads: Int
    var globalDownloadLimitBytesPerSec: Int?
    var globalUploadLimitBytesPerSec: Int?
    var notificationsEnabled: Bool
    var launchAtLogin: Bool

    static var `default`: AppSettings {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return AppSettings(
            defaultDownloadDirectory: downloads.appendingPathComponent("TorrentApp", isDirectory: true),
            maxParallelDownloads: 3,
            globalDownloadLimitBytesPerSec: nil,
            globalUploadLimitBytesPerSec: nil,
            notificationsEnabled: true,
            launchAtLogin: false
        )
    }
}
