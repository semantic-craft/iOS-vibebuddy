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

extension Color {
    /// A label on the accent. The dark accent is a mint, and white on mint
    /// fails contrast, so the label flips to ink there instead.
    static let onAccent = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 0.07, alpha: 1) : .white
    })
}

/// A glyph in a circle: the phone's toolbar unit. Sits on the page, not in a
/// bar, so the list scrolls under it.
struct PhoneCircleButton<Glyph: View>: View {
    var size: CGFloat = PhoneMetrics.control
    var tint: Color = CompanionPalette.ink
    var ground: Color = CompanionPalette.bg3
    let action: () -> Void
    @ViewBuilder var glyph: Glyph

    var body: some View {
        Button(action: action) {
            glyph
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(ground, in: Circle())
                .overlay(Circle().strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline))
                .contentShape(Circle())
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
struct PhoneSectionHeader: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(CompanionType.font(15, .medium))
                    .textCase(nil)   // a list style must not shout a group's name
                    .foregroundStyle(CompanionPalette.ink2)
                Text("\(count)")
                    .font(CompanionType.font(13, .medium)).monospacedDigit()
                    .foregroundStyle(CompanionPalette.ink3)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CompanionPalette.ink3)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityHint(expanded ? "Collapse" : "Expand")
    }
}

/// Rounded-rect buttons, the phone's answer to `PillButtonStyle`.
struct PhoneButtonStyle: ButtonStyle {
    enum Kind { case primary(Color), quiet, ghost }
    enum Size { case small, regular, wide }
    var kind: Kind = .quiet
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CompanionType.font(fontSize, .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, hPad).padding(.vertical, vPad)
            .frame(maxWidth: size == .wide ? .infinity : nil)
            .background(ground, in: RoundedRectangle(cornerRadius: PhoneMetrics.controlRadius, style: .continuous))
            .overlay {
                if !isPrimary {
                    RoundedRectangle(cornerRadius: PhoneMetrics.controlRadius, style: .continuous)
                        .strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: PhoneMetrics.controlRadius, style: .continuous))
    }

    private var isPrimary: Bool { if case .primary = kind { return true } else { return false } }
    private var fontSize: CGFloat { size == .small ? 12 : (size == .wide ? 15 : 13) }
    private var hPad: CGFloat { size == .small ? 10 : 14 }
    private var vPad: CGFloat { size == .small ? 6 : (size == .wide ? 11 : 8) }
    private var foreground: Color { isPrimary ? .onAccent : CompanionPalette.ink }
    private var ground: Color {
        switch kind {
        case .primary(let c): return c
        case .quiet: return CompanionPalette.bg3
        case .ghost: return .clear
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
                        .frame(width: 30, height: 32)
                        .contentShape(Rectangle())
                }
                .frame(width: 30, height: 32)
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CompanionType.font(13, .medium))
            .foregroundStyle(Color.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(color, in: UnevenRoundedRectangle(
                topLeadingRadius: PhoneMetrics.controlRadius,
                bottomLeadingRadius: PhoneMetrics.controlRadius,
                bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The hairline between rows, inset past the status dot like a settings list.
struct PhoneDivider: View {
    var leading: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(CompanionPalette.line)
            .frame(height: CompanionType.hairline)
            .padding(.leading, leading)
    }
}

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
