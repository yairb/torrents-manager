import SwiftUI

struct ContentView: View {
    @Environment(AppNavigationState.self) private var navigationState
    @Environment(AddTorrentViewModel.self) private var addTorrentViewModel
    @Environment(TorrentListViewModel.self) private var listViewModel

    var body: some View {
        @Bindable var navigationState = navigationState
        @Bindable var addTorrentViewModel = addTorrentViewModel

        VStack(spacing: 0) {
            Group {
                if let torrent = detailTorrent {
                    NavigationSplitView {
                        SidebarView(selectedCategory: $navigationState.selectedCategory)
                    } content: {
                        TorrentListView(category: navigationState.selectedCategory)
                    } detail: {
                        TorrentDetailView(torrent: torrent)
                    }
                } else {
                    NavigationSplitView {
                        SidebarView(selectedCategory: $navigationState.selectedCategory)
                    } detail: {
                        if navigationState.selectedCategory == .settings {
                            SettingsView()
                        } else {
                            TorrentListView(category: navigationState.selectedCategory)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addTorrentViewModel.isShowingAddMagnetSheet = true
                    } label: {
                        Label("Add Magnet", systemImage: "plus")
                    }
                }
            }

            // A sibling in a VStack, not a `.safeAreaInset` on the split view. As an inset the
            // bar was drawn over content that still believed it had the full window height:
            // the split view never passed the inset down to the List inside it, so the last row
            // stayed clipped behind the bar and could not be scrolled clear of it. Taking the
            // height out of the split view's layout outright is what the List actually honours.
            StatusBarView()
        }
        .sheet(isPresented: $addTorrentViewModel.isShowingAddMagnetSheet) {
            AddMagnetSheet()
        }
    }

    /// The torrent whose details should occupy a third column, if any.
    /// Settings has no torrent detail column, and a plain torrent list fills
    /// the full width whenever nothing is open for detail.
    private var detailTorrent: Torrent? {
        guard navigationState.selectedCategory != .settings else { return nil }
        return listViewModel.torrent(withID: navigationState.detailTorrentID)
    }
}
