import Foundation

struct AppSettings: Sendable, Codable, Equatable {
    var defaultDownloadDirectory: URL
    var maxParallelDownloads: Int
    var globalDownloadLimitBytesPerSec: Int?
    var globalUploadLimitBytesPerSec: Int?
    var notificationsEnabled: Bool
    var completionSoundEnabled: Bool
    var launchAtLogin: Bool
    var tags: [Tag]

    init(
        defaultDownloadDirectory: URL,
        maxParallelDownloads: Int,
        globalDownloadLimitBytesPerSec: Int?,
        globalUploadLimitBytesPerSec: Int?,
        notificationsEnabled: Bool,
        completionSoundEnabled: Bool = true,
        launchAtLogin: Bool,
        tags: [Tag] = []
    ) {
        self.defaultDownloadDirectory = defaultDownloadDirectory
        self.maxParallelDownloads = maxParallelDownloads
        self.globalDownloadLimitBytesPerSec = globalDownloadLimitBytesPerSec
        self.globalUploadLimitBytesPerSec = globalUploadLimitBytesPerSec
        self.notificationsEnabled = notificationsEnabled
        self.completionSoundEnabled = completionSoundEnabled
        self.launchAtLogin = launchAtLogin
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case defaultDownloadDirectory, maxParallelDownloads, globalDownloadLimitBytesPerSec
        case globalUploadLimitBytesPerSec, notificationsEnabled, completionSoundEnabled
        case launchAtLogin, tags
    }

    // Custom decoding so settings.json files saved before a later feature existed (and so lack
    // its key) still decode successfully instead of falling back to `.default`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultDownloadDirectory = try container.decode(URL.self, forKey: .defaultDownloadDirectory)
        maxParallelDownloads = try container.decode(Int.self, forKey: .maxParallelDownloads)
        globalDownloadLimitBytesPerSec = try container.decodeIfPresent(Int.self, forKey: .globalDownloadLimitBytesPerSec)
        globalUploadLimitBytesPerSec = try container.decodeIfPresent(Int.self, forKey: .globalUploadLimitBytesPerSec)
        notificationsEnabled = try container.decode(Bool.self, forKey: .notificationsEnabled)
        completionSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .completionSoundEnabled) ?? true
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        tags = try container.decodeIfPresent([Tag].self, forKey: .tags) ?? []
    }

    static var `default`: AppSettings {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return AppSettings(
            defaultDownloadDirectory: downloads.appendingPathComponent("TorrentApp", isDirectory: true),
            maxParallelDownloads: 3,
            globalDownloadLimitBytesPerSec: nil,
            globalUploadLimitBytesPerSec: nil,
            notificationsEnabled: true,
            completionSoundEnabled: true,
            launchAtLogin: false,
            tags: []
        )
    }
}
