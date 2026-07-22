import SwiftUI

struct SidebarView: View {
    @Binding var selectedCategory: SidebarCategory

    var body: some View {
        List(selection: $selectedCategory) {
            Section("Torrents") {
                ForEach(SidebarCategory.allCases.filter { $0 != .settings }) { category in
                    Label(category.rawValue, systemImage: category.systemImage)
                        .tag(category)
                }
            }
            Section {
                Label(SidebarCategory.settings.rawValue, systemImage: SidebarCategory.settings.systemImage)
                    .tag(SidebarCategory.settings)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    }
}
