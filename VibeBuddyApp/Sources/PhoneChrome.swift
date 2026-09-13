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
                               titleSize: 14, countSize: 12, chevronSize: 10, spacing: 6)
            .accessibilityLabel("\(title), \(count)")
    }
}

/// Rounded-rect buttons, the phone's answer to `PillButtonStyle`: the Kit's
/// `CompanionButtonStyle` at the phone's control radius.
struct PhoneButtonStyle: ButtonStyle {
    /// `soft` is the lightest key: the secondary ground, no edge — for the
    /// small verbs under a row (Reply, Jump) that must not weigh as much as
    /// an approval.
    enum Kind { case primary(Color), quiet, soft, ghost }
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
        case .soft: return .soft
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

/// The agent's mark alone, in its brand hue, with no tile behind it: the
/// Kit's `AgentAvatar` is the product tile for a sheet's head; on a row's
/// meta line the mark is enough and a tile is one more block.
struct AgentMark: View {
    let agent: AgentKind
    var size: CGFloat = 11

    var body: some View {
        SVGPathShape(agent.brandMark)
            .fill(agent.brandColor)
            .frame(width: size, height: size)
            .accessibilityLabel(agent.displayName)
    }
}

/// A sheet's head: a round close button on the left, the title centred, and
/// — when the sheet has one action of its own (Start, Done) — that action on
/// the right as a small key. Every sheet on the phone opens with this head;
/// none uses the system navigation bar.
struct PhoneSheetHeader<Trailing: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var trailing: Trailing

    init(title: String, close: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.close = close
        self.trailing = trailing()
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(CompanionType.font(17, .semibold))
                .tracking(CompanionType.tracking(17))
                .foregroundStyle(CompanionPalette.ink)
                .lineLimit(1)
            HStack {
                PhoneCircleButton("xmark", size: 32, tint: CompanionPalette.ink2, action: close)
                    .accessibilityLabel("Close")
                Spacer(minLength: 0)
                trailing
            }
        }
        .padding(.horizontal, PhoneMetrics.gutter)
        .padding(.top, 14).padding(.bottom, 12)
    }
}

extension PhoneSheetHeader where Trailing == EmptyView {
    init(title: String, close: @escaping () -> Void) {
        self.init(title: title, close: close) { EmptyView() }
    }
}

/// The phone's relative time: `now`, `5m`, `3h`, `2d`. Rows re-cut on the
/// page's 60-second clock and on every snapshot, so seconds would only
/// flicker; Cursor's rows say `5m` too.
enum PhoneRelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "now") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return String(localized: "\(minutes)m") }
        let hours = minutes / 60
        if hours < 24 { return String(localized: "\(hours)h") }
        return String(localized: "\(hours / 24)d")
    }

    /// The spoken form for accessibility (`5 minutes ago`).
    static func spoken(_ date: Date, now: Date = Date()) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }
}

/// One line about the page, above the list: a glyph, a short sentence, and
/// at most one key. The connection is said here, once; rows only add what
/// changes for them.
struct PhoneNotice<Action: View>: View {
    let symbol: String
    let text: String
    var tint: Color = CompanionPalette.ink2
    @ViewBuilder var action: Action

    init(symbol: String, text: String, tint: Color = CompanionPalette.ink2,
         @ViewBuilder action: () -> Action) {
        self.symbol = symbol
        self.text = text
        self.tint = tint
        self.action = action()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(CompanionType.font(12))
                .foregroundStyle(CompanionPalette.ink2)
                .lineLimit(2)
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard()
    }
}

extension PhoneNotice where Action == EmptyView {
    init(symbol: String, text: String, tint: Color = CompanionPalette.ink2) {
        self.init(symbol: symbol, text: text, tint: tint) { EmptyView() }
    }
}

/// An empty page in the phone's own type: a glyph, a title, a line, and at
/// most one key. The system's `ContentUnavailableView` sets SF Pro, which
/// no surface keeps (ADR-0017 §1).
struct PhoneEmptyState<Action: View>: View {
    let symbol: String
    let title: String
    var text: String? = nil
    @ViewBuilder var action: Action

    init(symbol: String, title: String, text: String? = nil, @ViewBuilder action: () -> Action) {
        self.symbol = symbol
        self.title = title
        self.text = text
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(CompanionPalette.ink3)
                .padding(.bottom, 2)
            Text(title)
                .font(CompanionType.font(17, .semibold))
                .tracking(CompanionType.tracking(17))
                .foregroundStyle(CompanionPalette.ink)
            if let text {
                Text(text)
                    .font(CompanionType.font(13))
                    .foregroundStyle(CompanionPalette.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PhoneMetrics.gutter + 8)
        .padding(.vertical, 40)
    }
}

extension PhoneEmptyState where Action == EmptyView {
    init(symbol: String, title: String, text: String? = nil) {
        self.init(symbol: symbol, title: title, text: text) { EmptyView() }
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
