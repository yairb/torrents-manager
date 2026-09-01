import AppKit
import Foundation
import SwiftUI

@main
struct TorrentAppMain: App {
    @State private var navigationState = AppNavigationState()
    @State private var listViewModel: TorrentListViewModel
    @State private var addTorrentViewModel: AddTorrentViewModel
    @State private var settingsManager: SettingsManager
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
                    // Only now is it safe to add torrents — before this the engine isn't running
                    // and the default download directory hasn't been loaded. Any magnet that
                    // launched the app has been buffered by the delegate and drains here.
                    appDelegate.setHandler { urls in handleOpenedURLs(urls) }
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
            // The whole group is replaced rather than adding a ⌘V button alongside it: a second
            // ⌘V binding would shadow the standard one and break pasting into every text field in
            // the app. Cut/Copy/Select All are re-provided verbatim by forwarding to the responder
            // chain, exactly as the stock items do.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x", modifiers: .command)
                Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") { paste() }
                    .keyboardShortcut("v", modifiers: .command)
                Divider()
                Button("Select All") { NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil) }
                    .keyboardShortcut("a", modifiers: .command)
            }
        }
    }

    /// Handles `magnet:` links and `.torrent` files opened from Finder, a browser, or `open(1)`.
    /// Info.plist claims both; without this they'd foreground the app and do nothing.
    @MainActor
    private func handleOpenedURLs(_ urls: [URL]) {
        let magnets = urls.filter { $0.scheme?.lowercased() == "magnet" }.map(\.absoluteString)
        if !magnets.isEmpty {
            addTorrentViewModel.addMagnets(magnets)
        }
        for url in urls where url.isFileURL && url.pathExtension.lowercased() == "torrent" {
            addTorrentViewModel.submitTorrentFile(at: url)
        }
    }

    /// ⌘V adds the clipboard's magnet links — unless a text field has focus, in which case it must
    /// behave like an ordinary paste.
    @MainActor
    private func paste() {
        // A SwiftUI TextField resolves to the window's field editor (an NSTextView) while editing.
        let isEditingText = NSApp.keyWindow?.firstResponder is NSTextView
        if !isEditingText, addTorrentViewModel.addMagnetsFromClipboard() {
            return
        }
        // Nothing magnet-shaped on the clipboard (or a field is focused): forward it along so the
        // paste is never silently swallowed.
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
    }
}
