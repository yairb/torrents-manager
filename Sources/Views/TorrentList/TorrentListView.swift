import SwiftUI

struct TorrentListView: View {
    let category: SidebarCategory
    @Environment(TorrentListViewModel.self) private var viewModel
    @Environment(AddTorrentViewModel.self) private var addTorrentViewModel
    @Environment(AppNavigationState.self) private var navigationState

    var body: some View {
        @Bindable var viewModel = viewModel
        let items = viewModel.torrents(for: category)

        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Torrents",
                    systemImage: "tray",
                    description: Text("Add a magnet link or drop a .torrent file to get started.")
                )
            } else {
                List(items, selection: bindingForSelection()) { torrent in
                    TorrentRowView(
                        torrent: torrent,
                        isSelected: torrent.id == navigationState.selectedTorrentID || torrent.id == navigationState.detailTorrentID,
                        onShowDetails: { navigationState.detailTorrentID = torrent.id }
                    )
                    .tag(torrent.id)
                    .id(torrent.id)
                    .contentShape(Rectangle())
                    .gesture(
                        TapGesture(count: 2)
                            .onEnded { select(torrent, openDetail: true) }
                            .exclusively(before: TapGesture(count: 1).onEnded { select(torrent, openDetail: false) })
                    )
                    .contextMenu {
                        torrentContextMenu(for: torrent)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onDeleteCommand {
                    guard let id = navigationState.selectedTorrentID,
                          let torrent = viewModel.torrent(withID: id),
                          torrent.status != .downloading else { return }
                    viewModel.remove(torrent, deleteFiles: false)
                }
            }
        }
        .navigationTitle(category.rawValue)
        .dropDestination(for: String.self) { items, _ in
            addTorrentViewModel.handleDroppedMagnetLinks(items)
            return true
        }
        .dropDestination(for: URL.self) { urls, _ in
            addTorrentViewModel.handleDroppedTorrentFiles(urls)
            return true
        }
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            ),
            presenting: viewModel.errorMessage
        ) { _ in
            Button("OK") { viewModel.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func bindingForSelection() -> Binding<TorrentHandleID?> {
        Binding(
            get: { navigationState.selectedTorrentID },
            set: { navigationState.selectedTorrentID = $0 }
        )
    }

    /// Selection is driven explicitly from our own tap gesture rather than
    /// List's built-in click-to-select — attaching any gesture to a row was
    /// found to block List's native selection handling on macOS, so instead
    /// we own the state update ourselves and just let List observe it.
    private func select(_ torrent: Torrent, openDetail: Bool) {
        navigationState.selectedTorrentID = torrent.id
        if openDetail || navigationState.detailTorrentID != nil {
            navigationState.detailTorrentID = torrent.id
        }
    }

    @ViewBuilder
    private func torrentContextMenu(for torrent: Torrent) -> some View {
        Button("Show Details") { navigationState.detailTorrentID = torrent.id }
        Divider()
        if torrent.status == .paused {
            Button("Resume") { viewModel.resume(torrent) }
        } else {
            Button("Pause") { viewModel.pause(torrent) }
        }
        Divider()
        Button("Remove", role: .destructive) { viewModel.remove(torrent, deleteFiles: false) }
        Button("Remove and Delete Files", role: .destructive) { viewModel.remove(torrent, deleteFiles: true) }
    }
}
