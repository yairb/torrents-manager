import AppKit
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
                .onOpenURL { url in
                    // Info.plist claims the `magnet` scheme and the `.torrent` file type; without
                    // this, clicking a magnet in a browser just foregrounds the app and does nothing.
                    if url.scheme?.lowercased() == "magnet" {
                        addTorrentViewModel.addMagnets([url.absoluteString])
                    } else if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
                        addTorrentViewModel.submitTorrentFile(at: url)
                    }
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
