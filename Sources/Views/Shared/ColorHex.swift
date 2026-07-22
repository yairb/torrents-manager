import AppKit
import SwiftUI

extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&rgb)
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.deviceRGB) else { return "#000000" }
        let r = Int(round(components.redComponent * 255))
        let g = Int(round(components.greenComponent * 255))
        let b = Int(round(components.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    var isLight: Bool {
        guard let components = NSColor(self).usingColorSpace(.deviceRGB) else { return false }
        let luminance = 0.299 * components.redComponent + 0.587 * components.greenComponent + 0.114 * components.blueComponent
        return luminance > 0.6
    }
}

extension Tag {
    var color: Color { Color(hex: colorHex) }
}
