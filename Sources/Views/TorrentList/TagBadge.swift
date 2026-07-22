import SwiftUI

struct TagBadge: View {
    let tag: Tag

    var body: some View {
        Text(tag.name)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tag.color, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(tag.color.isLight ? .black : .white)
    }
}
