import Foundation

/// Simple JSON-file-backed persistence, storing state under
/// ~/Library/Application Support/TorrentApp/. Conforms to `PersistenceStore` so it can be
/// swapped for a GRDB/SQLite implementation later without touching any caller.
actor JSONFilePersistenceStore: PersistenceStore {
    private let appSupportDirectory: URL
    private let settingsFileURL: URL
    private let torrentsDirectory: URL

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        appSupportDirectory = base.appendingPathComponent("TorrentApp", isDirectory: true)
        settingsFileURL = appSupportDirectory.appendingPathComponent("settings.json")
        torrentsDirectory = appSupportDirectory.appendingPathComponent("Torrents", isDirectory: true)
        try? FileManager.default.createDirectory(at: torrentsDirectory, withIntermediateDirectories: true)
    }

    func loadSettings() async -> AppSettings? {
        guard let data = try? Data(contentsOf: settingsFileURL) else { return nil }
        return try? decoder.decode(AppSettings.self, from: data)
    }

    func saveSettings(_ settings: AppSettings) async {
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: settingsFileURL, options: .atomic)
    }

    func fetchAllTorrents() async -> [TorrentRecord] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: torrentsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> TorrentRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(TorrentRecord.self, from: data)
            }
    }

    func saveTorrent(_ record: TorrentRecord) async {
        guard let data = try? encoder.encode(record) else { return }
        let url = torrentsDirectory.appendingPathComponent("\(record.id).json")
        try? data.write(to: url, options: .atomic)
    }

    func deleteTorrent(_ id: TorrentHandleID) async {
        let url = torrentsDirectory.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
    }
}
