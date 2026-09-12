import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The flat chrome the phone (ADR-0014), the menu panel (ADR-0015) and the
// Watch (ADR-0017 §7) share: a quiet group head with a count, a hairline
// between rows, and rounded-rect buttons in three weights. Each surface keeps
// its own sizes and insets; the drawing lives here once.

public extension Color {
    /// A label on the accent or a status fill. The dark accent is a mint, and
    /// white on mint fails contrast, so the label flips to ink there. watchOS
    /// is always dark, so it takes the ink outright.
    static let onAccent: Color = {
        #if os(iOS)
        return Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.07, alpha: 1) : .white
        })
        #elseif os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.07, alpha: 1) : .white
        })
        #else
        return Color(white: 0.07)
        #endif
    }()
}

/// The head of a group: name, count, and — when `expanded` is bound — a
/// chevron that turns. Never shouts: the rows' own status dots carry urgency,
/// so the heading is quiet ink on the ground. Without a binding it is a plain
/// label, for a group that cannot fold.
public struct CompanionSectionHeader: View {
    public let title: Text
    public let count: Int
    public var expanded: Binding<Bool>?
    public var titleSize: CGFloat
    public var countSize: CGFloat
    public var chevronSize: CGFloat
    public var spacing: CGFloat
    public var insets: EdgeInsets

    public init(title: Text, count: Int, expanded: Binding<Bool>? = nil,
                titleSize: CGFloat = 12, countSize: CGFloat = 11, chevronSize: CGFloat = 9,
                spacing: CGFloat = 5, insets: EdgeInsets = EdgeInsets()) {
        self.title = title
        self.count = count
        self.expanded = expanded
        self.titleSize = titleSize
        self.countSize = countSize
        self.chevronSize = chevronSize
        self.spacing = spacing
        self.insets = insets
    }

    public init(title: String, count: Int, expanded: Binding<Bool>? = nil,
                titleSize: CGFloat = 12, countSize: CGFloat = 11, chevronSize: CGFloat = 9,
                spacing: CGFloat = 5, insets: EdgeInsets = EdgeInsets()) {
        self.init(title: Text(verbatim: title), count: count, expanded: expanded,
                  titleSize: titleSize, countSize: countSize, chevronSize: chevronSize,
                  spacing: spacing, insets: insets)
    }

    public var body: some View {
        if let expanded {
            Button { withAnimation(.smooth(duration: 0.2)) { expanded.wrappedValue.toggle() } } label: {
                label(chevron: expanded.wrappedValue)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(expanded.wrappedValue ? Text("Collapse") : Text("Expand"))
        } else {
            label(chevron: nil)
                .accessibilityElement(children: .combine)
        }
    }

    private func label(chevron expanded: Bool?) -> some View {
        HStack(spacing: spacing) {
            title
                .font(CompanionType.font(titleSize, .medium))
                .textCase(nil)   // a list style must not shout a group's name
                .foregroundStyle(CompanionPalette.ink2)
            Text("\(count)")
                .font(CompanionType.font(countSize, .medium)).monospacedDigit()
                .foregroundStyle(CompanionPalette.ink3)
            if let expanded {
                Image(systemName: "chevron.down")
                    .font(.system(size: chevronSize, weight: .semibold))
                    .foregroundStyle(CompanionPalette.ink3)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            Spacer(minLength: 0)
        }
        .padding(insets)
        .contentShape(Rectangle())
    }
}

/// The hairline between rows, inset past the status dot like a settings list.
public struct CompanionHairline: View {
    public var leading: CGFloat

    public init(leading: CGFloat = 0) { self.leading = leading }

    public var body: some View {
        Rectangle()
            .fill(CompanionPalette.line)
            .frame(height: CompanionType.hairline)
            .padding(.leading, leading)
    }
}

/// Rounded-rect buttons, the flat surfaces' answer to `PillButtonStyle`:
/// `filled` (a colour of its own, with the on-accent label), `quiet` (the
/// card ground on a hairline), `soft` (the secondary ground, no edge) and
/// `ghost` (a hairline alone). No shadow, no capsule.
public struct CompanionButtonStyle: ButtonStyle {
    public enum Kind { case filled(Color), quiet, soft, ghost }
    public enum Size { case small, regular, wide }
    public var kind: Kind
    public var size: Size
    public var radius: CGFloat

    public init(kind: Kind = .quiet, size: Size = .regular, radius: CGFloat = CompanionType.cardRadius) {
        self.kind = kind
        self.size = size
        self.radius = radius
    }

    public func makeBody(configuration: Configuration) -> some View {
        // The environment is read by the body view, not the style, so a
        // surface's own style can wrap this one and `disabled` still dims.
        Rendered(configuration: configuration, kind: kind, size: size, radius: radius)
    }

    private struct Rendered: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size
        let radius: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .font(CompanionType.font(fontSize, .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, hPad).padding(.vertical, vPad)
                .frame(maxWidth: size == .wide ? .infinity : nil)
                .background(ground, in: shape)
                .overlay {
                    if hasEdge { shape.strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline) }
                }
                .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
                .animation(.smooth(duration: 0.12), value: configuration.isPressed)
                .contentShape(shape)
        }

        private var isFilled: Bool { if case .filled = kind { return true } else { return false } }
        private var hasEdge: Bool {
            switch kind {
            case .quiet, .ghost: return true
            case .filled, .soft: return false
            }
        }
        private var fontSize: CGFloat { size == .small ? 12 : (size == .wide ? 15 : 13) }
        private var hPad: CGFloat { size == .small ? 10 : 14 }
        private var vPad: CGFloat { size == .small ? 6 : (size == .wide ? 11 : 8) }
        private var foreground: Color { isFilled ? .onAccent : CompanionPalette.ink }
        private var ground: Color {
            switch kind {
            case .filled(let c): return c
            case .quiet: return CompanionPalette.bg3
            case .soft: return CompanionPalette.bg2
            case .ghost: return .clear
            }
        }
    }
}

/// The status dot: one per row, in the state's colour. The idle dot is the
/// only one that reads as "nothing to see".
public struct StatusDot: View {
    public let state: TaskPresentationState
    public var size: CGFloat

    public init(state: TaskPresentationState, size: CGFloat = 7) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(CompanionPalette.status(state))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
