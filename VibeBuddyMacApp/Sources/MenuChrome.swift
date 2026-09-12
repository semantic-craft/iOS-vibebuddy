import SwiftUI
import VibeBuddyKit

/// The menu panel's chrome (ADR-0015): Cursor's flat list register — round
/// glyph buttons, collapsible group heads, hairlines between rows instead of a
/// tinted block and a rail. Every colour and face comes from the Kit through
/// `MacTheme`; only the sizes are the panel's own.
enum MenuMetrics {
    static let gutter: CGFloat = 13
    static let control: CGFloat = 26
    /// The lane the status dot rides in. A row's second line, and the hairline
    /// under it, start where the title does.
    static let dotLane: CGFloat = 16
}

/// A glyph in a circle: the panel's toolbar unit at 26pt. Hover lifts the
/// ground, as every other control in the panel does.
struct MenuCircleButton: View {
    let systemName: String
    var size: CGFloat = MenuMetrics.control
    var tint: Color = MacTheme.ink
    var ground: Color = MacTheme.bg2
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(hovering ? ground.opacity(0.75) : ground, in: Circle())
                .overlay(Circle().strokeBorder(MacTheme.line, lineWidth: CompanionType.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The head of a collapsible group: name, count, and a chevron that turns.
/// Never shouts — the rows' own status dots carry urgency, so the heading is
/// quiet ink on the panel's ground.
struct MenuSectionHeader: View {
    let title: LocalizedStringKey
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button { withAnimation(.smooth(duration: 0.18)) { expanded.toggle() } } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(MacTheme.font(12, .medium))
                    .foregroundStyle(MacTheme.ink2)
                Text("\(count)")
                    .font(MacTheme.font(11, .medium)).monospacedDigit()
                    .foregroundStyle(MacTheme.ink3)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MacTheme.ink3)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MenuMetrics.gutter)
            .padding(.top, 9).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(expanded ? "Collapse" : "Expand")
    }
}

/// The hairline between rows, inset past the status dot like a settings list.
struct MenuHairline: View {
    var leading: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(MacTheme.line)
            .frame(height: CompanionType.hairline)
            .padding(.leading, leading)
    }
}
