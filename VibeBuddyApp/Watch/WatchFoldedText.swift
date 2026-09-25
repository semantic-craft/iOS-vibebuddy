import SwiftUI
import VibeBuddyKit

/// A text the wrist shows whole, scrolled with the Crown — or, past its limit,
/// as a preview with **Show more** that expands in place (`WatchReadingFold`,
/// M-07). Nothing is cut off for good: the rest is always one tap away, on the
/// same page, and VoiceOver always reads the whole text.
struct WatchFoldedText: View {
    let text: String
    let limit: Int
    var font: Font = CompanionType.font(12)
    var color: Color = CompanionPalette.ink

    /// The text that was expanded, not a flag: a new request under the same
    /// card is folded from its first frame, with no stale expanded render.
    @State private var expandedText: String?

    var body: some View {
        let fold = WatchReadingFold(text, limit: limit)
        let expanded = expandedText == text
        return VStack(alignment: .leading, spacing: 2) {
            Text(expanded ? fold.full : fold.preview)
                .font(font)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(fold.full)
            if fold.isFolded {
                Button {
                    expandedText = expanded ? nil : text
                } label: {
                    Text(expanded ? "Show less" : "Show more")
                        .font(CompanionType.font(11, .semibold))
                        .foregroundStyle(CompanionPalette.accent)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
    }
}
