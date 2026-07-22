import Foundation
import SwiftUI

@main
struct TorrentAppMain: App {
    @State private var navigationState = AppNavigationState()
    @State private var listViewModel: TorrentListViewModel
    @State private var addTorrentViewModel: AddTorrentViewModel
    @State private var settingsManager: SettingsManager

    private let downloadManager: DownloadManager

    init() {
        let store = JSONFilePersistenceStore()
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let sessionDirectory = appSupport.appendingPathComponent("TorrentApp/LibtorrentSession", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let engine = RealTorrentEngine(sessionDirectory: sessionDirectory)
        let manager = DownloadManager(engine: engine, persistenceStore: store)
        let settings = SettingsManager(persistenceStore: store, downloadManager: manager)

        self.downloadManager = manager
        _settingsManager = State(initialValue: settings)
        _listViewModel = State(initialValue: TorrentListViewModel(downloadManager: manager))
        _addTorrentViewModel = State(initialValue: AddTorrentViewModel(downloadManager: manager, settingsManager: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(navigationState)
                .environment(listViewModel)
                .environment(addTorrentViewModel)
                .environment(settingsManager)
                .task {
                    await settingsManager.reload()
                    try? await downloadManager.start()
                    await listViewModel.startObserving()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Magnet Link…") {
                    addTorrentViewModel.isShowingAddMagnetSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
