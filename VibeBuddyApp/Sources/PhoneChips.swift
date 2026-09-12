import SwiftUI
import VibeBuddyKit

/// Cursor's filter chip in the phone's rectangles: outlined at rest, ink-filled
/// when on. The task sheet's notification level is a row of these, so the
/// card carries no system segmented control (ADR-0017, ticket 10).
struct PhoneChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PhoneMetrics.controlRadius - 3, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(CompanionType.font(12, .medium))
                .foregroundStyle(selected ? Color.onAccentInk : CompanionPalette.ink2)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(selected ? CompanionPalette.ink : .clear, in: shape)
                .overlay { shape.strokeBorder(selected ? .clear : CompanionPalette.line, lineWidth: CompanionType.hairline) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension Color {
    /// The label on an ink-filled chip: the ground colour, which flips with
    /// the scheme the same way ink does.
    static var onAccentInk: Color { CompanionPalette.bg }
}
