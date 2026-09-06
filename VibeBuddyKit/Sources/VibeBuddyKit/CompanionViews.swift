import SwiftUI

// MARK: - Cards

private struct CompanionCardShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.shadow(color: scheme == .dark ? .black.opacity(0.2) : Color(hex: 0x2B3247).opacity(0.05),
                       radius: 2, y: 1)
    }
}

public extension View {
    /// A Companion card: `bg3` ground, continuous corners, one soft shadow.
    func companionCard(_ ground: Color = CompanionPalette.bg3,
                       radius: CGFloat = CompanionType.cardRadius) -> some View {
        background(ground, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .modifier(CompanionCardShadow())
    }
}

// MARK: - Controls

/// Pill buttons in three weights: `filled` (a colour of its own — approve,
/// deny, primary), `ghost` (outlined) and `soft` (secondary ground).
public struct PillButtonStyle: ButtonStyle {
    public enum Kind { case filled(Color), ghost, soft }
    public enum Size { case regular, small, large }
    public var kind: Kind
    public var size: Size

    public init(kind: Kind = .soft, size: Size = .regular) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CompanionType.font(fontSize, .heavy))
            .foregroundStyle(foreground)
            .padding(.horizontal, hPad).padding(.vertical, vPad)
            .frame(maxWidth: size == .large ? .infinity : nil)
            .background(background, in: Capsule())
            .overlay {
                if case .ghost = kind { Capsule().strokeBorder(CompanionPalette.line, lineWidth: 2) }
            }
            .shadow(color: shadowColor, radius: 6, y: 3)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private var fontSize: CGFloat { size == .small ? 11 : (size == .large ? 15 : 13) }
    private var hPad: CGFloat { size == .small ? 12 : 16 }
    private var vPad: CGFloat { size == .small ? 5 : (size == .large ? 12 : 8) }
    private var foreground: Color {
        if case .filled = kind { return .white }
        return CompanionPalette.ink
    }
    private var background: Color {
        switch kind {
        case .filled(let c): return c
        case .ghost: return .clear
        case .soft: return CompanionPalette.bg2
        }
    }
    private var shadowColor: Color {
        if case .filled(let c) = kind { return c.opacity(0.28) }
        return .clear
    }
}

/// The small tinted circle that carries a session's state on a summary-first row.
public struct StateGlyph: View {
    public let state: TaskPresentationState
    public var size: CGFloat
    public var onDark: Bool

    public init(state: TaskPresentationState, size: CGFloat = 32, onDark: Bool = false) {
        self.state = state
        self.size = size
        self.onDark = onDark
    }

    public var body: some View {
        let tint = CompanionPalette.status(state)
        let quiet = state == .idle && !onDark
        ZStack {
            Circle().fill(quiet ? CompanionPalette.bg2 : tint.opacity(onDark ? 0.28 : 0.16))
            Image(systemName: state.symbolName)
                .font(.system(size: size * 0.42, weight: .bold, design: .monospaced))
                .foregroundStyle(quiet ? CompanionPalette.ink3 : tint)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.label)
    }
}

/// The agent's product tile: its monochrome mark in its brand hue on a light
/// wash of the same hue, in a rounded square. Square says "product" next to
/// the round pet and round status dots; the wash keeps a row of them quiet on
/// the Companion ground, and black-and-white brands draw in ink instead of as
/// solid black discs.
public struct AgentAvatar: View {
    public let agent: AgentKind
    public var size: CGFloat

    public init(agent: AgentKind, size: CGFloat = 32) {
        self.agent = agent
        self.size = size
    }

    public var body: some View {
        let tint = agent.brandColor
        SVGPathShape(agent.brandMark)
            .fill(tint)
            .frame(width: size * 0.56, height: size * 0.56)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityLabel(agent.displayName)
    }
}

/// The agent's short name in a small rounded badge.
public struct AgentBadge: View {
    public let agent: AgentKind
    public var onDark: Bool

    public init(agent: AgentKind, onDark: Bool = false) {
        self.agent = agent
        self.onDark = onDark
    }

    public var body: some View {
        Text(agent.shortName)
            .font(CompanionType.font(10, .heavy))
            .foregroundStyle(onDark ? .white : CompanionPalette.ink2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(onDark ? Color.white.opacity(0.14) : CompanionPalette.bg2, in: Capsule())
    }
}

/// `<Title> <count>` — the head of a state bucket.
public struct BucketTitle: View {
    public let title: String
    public let count: Int
    public var onDark: Bool

    public init(title: String, count: Int, onDark: Bool = false) {
        self.title = title
        self.count = count
        self.onDark = onDark
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(title).font(CompanionType.font(14, .black))
                .foregroundStyle(onDark ? .white : CompanionPalette.ink)
            Text("\(count)").font(CompanionType.font(12, .heavy)).monospacedDigit()
                .foregroundStyle(onDark ? .white.opacity(0.6) : CompanionPalette.ink2)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

#if os(iOS) || os(macOS)
/// `Approve ▾`: the left half approves once, the chevron opens the two wider
/// grants. One green pill, because the system's split menu button ignores the
/// prominent tint on macOS.
public struct SplitApproveButton: View {
    public let approve: () -> Void
    public let always: () -> Void
    public let session: () -> Void
    private let green = CompanionPalette.status(.completeUnread)

    public init(approve: @escaping () -> Void, always: @escaping () -> Void, session: @escaping () -> Void) {
        self.approve = approve
        self.always = always
        self.session = session
    }

    public var body: some View {
        HStack(spacing: 1) {
            Button(String(localized: "Approve"), action: approve)
                .buttonStyle(SplitHalfStyle(color: green))
            Menu {
                Button(String(localized: "Always allow this"), action: always)
                Button(String(localized: "Allow all this session"), action: session)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 34)
                    .contentShape(Rectangle())
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #endif
            .frame(width: 32, height: 34)
            .background(green, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                                          bottomTrailingRadius: 17, topTrailingRadius: 17,
                                                          style: .continuous))
            .accessibilityLabel(String(localized: "More approval options"))
        }
        .shadow(color: green.opacity(0.28), radius: 6, y: 3)
    }
}

private struct SplitHalfStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CompanionType.font(13, .heavy))
            .foregroundStyle(.white)
            .padding(.leading, 16).padding(.trailing, 12)
            .frame(height: 34)
            .background(color, in: UnevenRoundedRectangle(topLeadingRadius: 17, bottomLeadingRadius: 17,
                                                          bottomTrailingRadius: 0, topTrailingRadius: 0,
                                                          style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The pending tool call by type: the full Bash command, an Edit diff
/// (old → new), a Write preview, or just the path. Falls back to
/// `commandPreview` when no rich fields are present.
public struct ApprovalBody: View {
    public let approval: PendingApproval
    public var onDark: Bool
    private static let maxDiffLines = 8

    public init(approval: PendingApproval, onDark: Bool = false) {
        self.approval = approval
        self.onDark = onDark
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = approval.filePath {
                Label(path, systemImage: "doc.text")
                    .font(CompanionType.mono(12, .medium))
                    .foregroundStyle(onDark ? .white : CompanionPalette.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(block, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let cmd = approval.command {
                codeBlock(cmd)
            } else if let old = approval.oldText {
                diff(old: old, new: approval.newText ?? "")
            } else if let new = approval.newText {
                codeBlock(new)
            } else if approval.filePath == nil {
                codeBlock(approval.commandPreview)
            }
        }
    }

    private var block: Color { onDark ? Color.white.opacity(0.08) : CompanionPalette.bg2 }
    private var ink: Color { onDark ? .white : CompanionPalette.ink }

    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text).font(CompanionType.mono(12)).lineLimit(14).textSelection(.enabled)
                .foregroundStyle(ink)
        }
        .padding(10)
        .background(block, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func diff(old: String, new: String) -> some View {
        let oldLines = capped(old)
        let newLines = capped(new)
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(oldLines.lines.enumerated()), id: \.offset) { _, l in
                    diffLine("-", l, CompanionPalette.status(.error))
                }
                ForEach(Array(newLines.lines.enumerated()), id: \.offset) { _, l in
                    diffLine("+", l, CompanionPalette.status(.completeUnread))
                }
                if oldLines.truncated || newLines.truncated {
                    Text("… (truncated)").font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink3).padding(.leading, 6)
                }
            }
        }
        .padding(8)
        .background(block, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func diffLine(_ sign: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(sign).foregroundStyle(color).fontWeight(.bold)
            Text(text.isEmpty ? " " : text).foregroundStyle(ink)
        }
        .font(CompanionType.mono(12))
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }

    private func capped(_ s: String) -> (lines: [String], truncated: Bool) {
        let all = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if all.count <= Self.maxDiffLines { return (all, false) }
        return (Array(all.prefix(Self.maxDiffLines)), true)
    }
}
#endif

// MARK: - Speech bubble

/// A rounded card with a small tail pointing at the cat on its left.
public struct SpeechBubble<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 9)
            .companionCard()
            .background(alignment: .leading) {
                BubbleTail().fill(CompanionPalette.bg3)
                    .frame(width: 8, height: 14)
                    .offset(x: -7, y: 0)
            }
    }
}

private struct BubbleTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
