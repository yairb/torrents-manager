import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AddMagnetSheet: View {
    @Environment(AddTorrentViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(alignment: .leading, spacing: 16) {
            Text("Add Torrent")
                .font(.title2.bold())

            TextField("magnet:?xt=urn:btih:...", text: $viewModel.magnetURIInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .onSubmit { viewModel.submitMagnetLink() }

            HStack {
                Rectangle().fill(.quaternary).frame(height: 1)
                Text("or").foregroundStyle(.secondary).font(.caption)
                Rectangle().fill(.quaternary).frame(height: 1)
            }

            Button {
                chooseTorrentFile()
            } label: {
                Label("Choose .torrent File…", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { viewModel.submitMagnetLink() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.magnetURIInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func chooseTorrentFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.submitTorrentFile(at: url)
    }
}
