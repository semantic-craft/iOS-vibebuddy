import SwiftUI
import VibeBuddyKit

/// The phone's first axis (ADR-0031): the Mac's agent rail laid on its side.
/// One tile per agent reporting, **All** first, each ringed by what that
/// account has left and dotted when one of its sessions is blocked on you.
/// Choosing one scopes everything under it — the tiles, First up, the project
/// list and the list page it opens — and the choice survives Back, because the
/// agent is a place, not a filter you clear.
struct PhoneAgentStrip: View {
    let items: [AgentRoster.Item]
    let quotas: [ProviderQuota]
    @Binding var selection: AgentKind?
    let now: Date

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    PhoneAgentTile(item: item, selected: selection == item.agent,
                                   reading: reading(for: item.agent), now: now) {
                        // The same selection feedback a segmented control gives.
                        UISelectionFeedbackGenerator().selectionChanged()
                        selection = item.agent
                    }
                }
            }
            .padding(.horizontal, PhoneMetrics.gutter)
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents")
        .accessibilityIdentifier("phone-agent-strip")
    }

    /// The agent's own allowance, or the fleet's tightest under All — the
    /// reading that would stop the next turn either way.
    private func reading(for agent: AgentKind?) -> QuotaReading? {
        guard let agent else { return quotas.tightestReading }
        return quotas.reading(for: agent)
    }
}

/// One agent on the strip: the brand mark inside its allowance ring, the short
/// name, and the count — in the attention tint when something is waiting, so
/// the strip answers "who needs me" before it is tapped.
struct PhoneAgentTile: View {
    let item: AgentRoster.Item
    let selected: Bool
    let reading: QuotaReading?
    let now: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    if let reading {
                        QuotaRing(fraction: Double(reading.usedPercent) / 100,
                                  tint: QuotaPresentation.severity(usedPercent: reading.usedPercent).tint,
                                  lineWidth: 2)
                            .frame(width: 34, height: 34)
                    }
                    mark
                }
                .frame(width: 38, height: 38)
                .overlay(alignment: .topTrailing) {
                    if item.tally.needsYou > 0 {
                        Circle().fill(CompanionPalette.status(.requiresInput))
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(CompanionPalette.bg, lineWidth: 1.5))
                    }
                }
                Text(name)
                    .font(CompanionType.font(11, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? CompanionPalette.accentText : CompanionPalette.ink2)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Text(verbatim: "\(item.tally.total)")
                    .font(CompanionType.mono(10)).monospacedDigit()
                    .foregroundStyle(item.tally.needsYou > 0
                                     ? CompanionPalette.status(.requiresInput) : CompanionPalette.ink3)
            }
            .frame(width: 64)
            .padding(.vertical, 8)
            .background(selected ? CompanionPalette.accent.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(verbatim: value))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var mark: some View {
        if let agent = item.agent {
            SVGPathShape(agent.brandMark)
                .fill(selected ? agent.brandColor : CompanionPalette.ink2)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 14, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? CompanionPalette.accent : CompanionPalette.ink2)
        }
    }

    private var name: String { item.agent?.shortName ?? String(localized: "All") }

    /// Everything the tile is too small to say, for VoiceOver.
    private var value: String {
        var parts = [item.tally.total == 1 ? String(localized: "1 session") : String(localized: "\(item.tally.total) sessions")]
        if item.tally.needsYou > 0 { parts.append(String(localized: "\(item.tally.needsYou) need you")) }
        if item.tally.working > 0 { parts.append(String(localized: "\(item.tally.working) working")) }
        if let reading {
            var quota = String(localized: "\(reading.remainingPercent)% left")
            if let reset = reading.resetsAt { quota += " · " + QuotaPresentation.resetCountdown(from: reset, now: now) }
            parts.append(quota)
        }
        return parts.joined(separator: ", ")
    }
}
