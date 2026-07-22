import AppKit
import SwiftUI

struct TagEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let existingID: UUID?
    private let onSave: (Tag) -> Void

    @State private var name: String
    @State private var color: Color
    @State private var scriptPath: URL?

    init(tag: Tag?, onSave: @escaping (Tag) -> Void) {
        self.existingID = tag?.id
        self.onSave = onSave
        _name = State(initialValue: tag?.name ?? "")
        _color = State(initialValue: tag.map { Color(hex: $0.colorHex) } ?? .red)
        _scriptPath = State(initialValue: tag?.scriptPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingID == nil ? "New Tag" : "Edit Tag")
                .font(.title2.bold())

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            ColorPicker("Color", selection: $color, supportsOpacity: false)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Script (optional)")
                    Spacer()
                    if let scriptPath {
                        Text(scriptPath.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Remove") { self.scriptPath = nil }
                    }
                    Button(scriptPath == nil ? "Choose…" : "Change…") { chooseScript() }
                }
                Text("Runs when a torrent with this tag finishes downloading. Receives the torrent name, destination path, info hash, and size as arguments and environment variables.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scriptPath = url
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let tag = Tag(id: existingID ?? UUID(), name: trimmed, colorHex: color.hexString, scriptPath: scriptPath)
        onSave(tag)
        dismiss()
    }
}
