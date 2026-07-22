import Foundation

struct Tag: Identifiable, Sendable, Codable, Equatable {
    var id: UUID
    var name: String
    var colorHex: String
    var scriptPath: URL?

    init(id: UUID = UUID(), name: String, colorHex: String, scriptPath: URL? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.scriptPath = scriptPath
    }
}
