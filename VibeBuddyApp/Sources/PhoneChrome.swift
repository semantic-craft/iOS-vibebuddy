import SwiftUI
import VibeBuddyKit

/// The iPhone's chrome (ADR-0014): round glyph buttons floating over a neutral
/// page, collapsible group heads, hairline-separated rows, rounded-rect buttons
/// instead of pills. It spends the Companion tokens — one palette and one type
/// ramp across the three apps — on a denser, flatter phone layout.
enum PhoneMetrics {
    static let gutter: CGFloat = 16
    static let control: CGFloat = 36
    static let controlRadius: CGFloat = 10
}

/// A glyph in a circle: the phone's toolbar unit. Sits on the page, not in a
/// bar, so the list scrolls under it.
struct PhoneCircleButton<Glyph: View>: View {
    var size: CGFloat = PhoneMetrics.control
    var tint: Color = CompanionPalette.ink
    var ground: Color = CompanionPalette.bg3
    let action: () -> Void
    @ViewBuilder var glyph: Glyph

    /// The smallest touch target; the circle keeps its drawn size inside it.
    static var touchTarget: CGFloat { 44 }

    var body: some View {
        Button(action: action) {
            glyph
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(ground, in: Circle())
                .overlay(Circle().strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline))
                // The tappable area is 44pt even when the circle is 30; the
                // extra is invisible and does not move the layout.
                .frame(width: max(size, Self.touchTarget), height: max(size, Self.touchTarget))
                .contentShape(Rectangle())
                .padding(-max(0, (Self.touchTarget - size) / 2))
        }
        .buttonStyle(.plain)
    }
}

extension PhoneCircleButton where Glyph == Image {
    init(_ systemName: String, size: CGFloat = PhoneMetrics.control,
         tint: Color = CompanionPalette.ink, ground: Color = CompanionPalette.bg3,
         action: @escaping () -> Void) {
        self.init(size: size, tint: tint, ground: ground, action: action) { Image(systemName: systemName) }
    }
}

/// The head of a collapsible group: name, count, and a chevron that turns.
/// The Kit's `CompanionSectionHeader` at the phone's sizes.
struct PhoneSectionHeader: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        CompanionSectionHeader(title: title, count: count, expanded: $expanded,
                               titleSize: 15, countSize: 13, chevronSize: 11, spacing: 6)
            .accessibilityLabel("\(title), \(count)")
    }
}

/// Rounded-rect buttons, the phone's answer to `PillButtonStyle`: the Kit's
/// `CompanionButtonStyle` at the phone's control radius.
struct PhoneButtonStyle: ButtonStyle {
    enum Kind { case primary(Color), quiet, ghost }
    enum Size { case small, regular, wide }
    var kind: Kind = .quiet
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        CompanionButtonStyle(kind: sharedKind, size: sharedSize, radius: PhoneMetrics.controlRadius)
            .makeBody(configuration: configuration)
    }

    private var sharedKind: CompanionButtonStyle.Kind {
        switch kind {
        case .primary(let c): return .filled(c)
        case .quiet: return .quiet
        case .ghost: return .ghost
        }
    }
    private var sharedSize: CompanionButtonStyle.Size {
        switch size {
        case .small: return .small
        case .regular: return .regular
        case .wide: return .wide
        }
    }
}

/// `Approve ▾` in the phone's rectangles: the left half approves once, the
/// chevron opens the two wider grants. The Kit's `SplitApproveButton` is a
/// capsule for the Mac; a pill next to these rows reads as a different app.
struct PhoneApproveButton: View {
    let approve: () -> Void
    let always: () -> Void
    let session: () -> Void
    var allowsPersistentDecision: Bool = true
    private let green = CompanionPalette.accent

    var body: some View {
        HStack(spacing: 1) {
            Button(String(localized: "Approve"), action: approve)
                .buttonStyle(PhoneApproveHalf(color: green, leading: true))
            if allowsPersistentDecision {
                Menu {
                    Button(String(localized: "Always allow this"), action: always)
                    Button(String(localized: "Allow all this session"), action: session)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.onAccent)
                        .frame(width: 30, height: PhoneApproveHalf.height)
                        // 44pt of touch around the 32pt key, drawn no larger.
                        .frame(height: PhoneApproveHalf.touchHeight)
                        .contentShape(Rectangle())
                }
                .frame(width: 30, height: PhoneApproveHalf.height)
                .background(green, in: UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 0,
                    bottomTrailingRadius: PhoneMetrics.controlRadius,
                    topTrailingRadius: PhoneMetrics.controlRadius, style: .continuous))
                .accessibilityLabel(String(localized: "More approval options"))
            }
        }
    }
}

private struct PhoneApproveHalf: ButtonStyle {
    let color: Color
    let leading: Bool
    /// The drawn height, and the touch height around it (invisible; the row
    /// keeps its 32pt key, the finger gets 44).
    static let height: CGFloat = 32
    static let touchHeight: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CompanionType.font(13, .medium))
            .foregroundStyle(Color.onAccent)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: Self.height)
            .background(color, in: UnevenRoundedRectangle(
                topLeadingRadius: PhoneMetrics.controlRadius,
                bottomLeadingRadius: PhoneMetrics.controlRadius,
                bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .frame(minHeight: Self.touchHeight)
            .contentShape(Rectangle())
            .padding(.vertical, -(Self.touchHeight - Self.height) / 2)
    }
}

/// The hairline between rows, inset past the status dot like a settings list.
typealias PhoneDivider = CompanionHairline

/// A sheet's head: a round close button on the left, the title centred.
struct PhoneSheetHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(CompanionType.font(17, .semibold))
                .tracking(CompanionType.tracking(17))
                .foregroundStyle(CompanionPalette.ink)
            HStack {
                PhoneCircleButton("xmark", size: 32, tint: CompanionPalette.ink2, action: close)
                    .accessibilityLabel("Close")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, PhoneMetrics.gutter)
        .padding(.top, 14).padding(.bottom, 12)
    }
}

extension View {
    /// One neutral ground under a sheet, and the phone's accent inside it.
    func phoneSheet() -> some View {
        self
            .background(CompanionPalette.bg)
            .tint(CompanionPalette.accent)
    }

    /// A `Form` / `List` restyled onto the phone's ground.
    func phoneList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(CompanionPalette.bg)
            .tint(CompanionPalette.accent)
    }
}
