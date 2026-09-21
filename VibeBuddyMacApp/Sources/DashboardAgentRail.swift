import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// The dashboard's first axis. "Which agent is on it" is the question the
/// window answers before "which checkout": one tile per agent reporting,
/// ringed by what that account has left, with a dot when one of its sessions
/// is blocked on you. "All agents" leads, so the whole fleet stays one click
/// away, and Settings sits at the foot — the one chrome row the rail keeps
/// whether or not the column beside it is folded.
struct DashboardAgentRail: View {
    @ObservedObject var model: MenuBarModel
    let items: [AgentRoster.Item]
    @Binding var selection: AgentKind?

    static let width: CGFloat = 48

    var body: some View {
        VStack(spacing: 2) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        AgentRailTile(item: item, selected: selection == item.agent,
                                      quota: reading(for: item.agent, now: context.date),
                                      now: context.date) {
                            selection = item.agent
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button { NotificationCenter.default.post(name: .openAppSettings, object: nil) } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MacTheme.ink2)
                    .frame(width: 38, height: 38)
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(RailTileStyle(selected: false))
            .help(Text("Settings  ⌘,"))
            .accessibilityLabel("Settings")
        }
        .padding(.vertical, 10)
        .frame(width: Self.width).frame(maxHeight: .infinity)
        .background(MacTheme.bg2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents")
    }

    /// The tile's ring: the agent's own allowance, or the fleet's tightest one
    /// under "All agents" — the reading that would stop the next turn.
    private func reading(for agent: AgentKind?, now: Date) -> AgentQuotaReading? {
        guard let agent else { return AgentQuotaReading.tightest(model: model, now: now) }
        return AgentQuotaReading.read(agent, model: model, now: now)
    }
}

struct AgentRailTile: View {
    let item: AgentRoster.Item
    let selected: Bool
    let quota: AgentQuotaReading?
    let now: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let quota {
                    QuotaRing(fraction: quota.fraction, tint: quota.tint).frame(width: 32, height: 32)
                }
                mark
            }
            .frame(width: 38, height: 38)
            .overlay(alignment: .topTrailing) {
                if item.tally.needsYou > 0 {
                    Circle().fill(MacTheme.status(.requiresInput))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(MacTheme.bg2, lineWidth: 1.5))
                        .offset(x: -1, y: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(RailTileStyle(selected: selected))
        .help(tip)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(reading))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var mark: some View {
        if let agent = item.agent {
            SVGPathShape(agent.brandMark)
                .fill(selected ? agent.brandColor : MacTheme.ink2)
                .frame(width: 15, height: 15)
        } else {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? MacTheme.accent : MacTheme.ink2)
        }
    }

    private var name: String { item.agent?.displayName ?? String(localized: "All agents") }

    /// What the tile would say if it had room: its counts, then its allowance.
    private var reading: String {
        var parts = [item.tally.total == 1 ? String(localized: "1 session") : String(localized: "\(item.tally.total) sessions")]
        if item.tally.needsYou > 0 { parts.append(String(localized: "\(item.tally.needsYou) need you")) }
        if item.tally.working > 0 { parts.append(String(localized: "\(item.tally.working) working")) }
        if let quota { parts.append(quota.summaryLine(now: now)) }
        return parts.joined(separator: " · ")
    }

    private var tip: Text { Text(name) + Text(" · ") + Text(reading) }
}

/// The rail's hit shape: the sidebar row's wash and selection, in a square
/// tile instead of a full-width row.
struct RailTileStyle: ButtonStyle {
    var selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ground(configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .onHover { hovering = $0 }
    }

    private func ground(_ pressed: Bool) -> Color {
        if selected { return MacTheme.accent.opacity(0.14) }
        if pressed { return MacTheme.ink.opacity(0.07) }
        return hovering ? MacTheme.ink.opacity(0.04) : .clear
    }
}
