import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct GlanceView: View {
    @ObservedObject var model: MenuBarModel
    let mode: GlanceMode

    private var s: CGFloat { model.glanceScale }
    private var expanded: Bool { model.glanceExpanded }
    private var groups: SessionGroups { SessionGroups(model.sessions) }
    private var pending: AgentSession? { model.sessions.first { $0.pendingApproval != nil } }
    private var width: CGFloat { (expanded ? 440 : 300) * s }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .padding(.horizontal, 20 * s).padding(.vertical, (expanded ? 16 : 9) * s)
            .frame(width: width, alignment: expanded ? .leading : .center)
            .background(background)
            .clipShape(clipShape)
            .onHover { hovering in
                model.setGlanceExpanded(hovering)
            }
    }

    @ViewBuilder private var content: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 8 * s) {
                HStack(spacing: 8 * s) {
                    counts
                    Button {
                        model.setShowGlance(false)   // get out of the way; ⌃⌥⇧⌘G or the menu brings it back
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13 * s))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help("Hide glance (\(model.toggleGlanceHotkey.displayString))")
                }
                if let p = pending, let a = p.pendingApproval {
                    Divider().overlay(.white.opacity(0.2))
                    Text(p.project).font(.system(size: 13 * s, weight: .bold)).foregroundStyle(.white)
                    Text(a.commandPreview).font(.system(size: 11 * s, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                    HStack {
                        Button("Approve") { model.decide(a.id, approve: true) }.tint(.green)
                        Button("Deny") { model.decide(a.id, approve: false) }.tint(.red)
                    }.buttonStyle(.borderedProminent).controlSize(.regular)
                } else {
                    ForEach(model.sessions.prefix(6)) { sess in
                        HStack(spacing: 8 * s) {
                            Circle().fill(color(sess.status)).frame(width: 8 * s, height: 8 * s)
                            Text(sess.project).font(.system(size: 13 * s)).foregroundStyle(.white).lineLimit(1)
                        }
                    }
                }
            }
        } else {
            counts
        }
    }

    private var counts: some View {
        HStack(spacing: 16 * s) {
            GlanceBuddy(state: BuddyState.from(groups, now: Date()), scale: s)
            countPill(groups.needsResponse.count, .orange)
            countPill(groups.working.count, .blue)
            countPill(groups.done.count, .green)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func countPill(_ n: Int, _ c: Color) -> some View {
        HStack(spacing: 7 * s) {
            Circle().fill(c).frame(width: 11 * s, height: 11 * s)
            Text("\(n)").font(.system(size: 17 * s, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        }
    }

    private func color(_ s: SessionStatus) -> Color {
        switch s {
        case .needsResponse: .orange
        case .working: .blue
        case .done: .green
        }
    }

    @ViewBuilder private var background: some View {
        if mode == .notch {
            NotchShape().fill(.black)
        } else {
            Capsule().fill(.black)
        }
    }

    private var clipShape: AnyShape {
        mode == .notch ? AnyShape(NotchShape()) : AnyShape(Capsule())
    }
}

/// The buddy inside the glance — a paw with the shared state badge, matching the
/// phone's moods so both surfaces read the same.
private struct GlanceBuddy: View {
    let state: BuddyState
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 15 * scale, weight: .semibold))
                .foregroundStyle(.white)
            Image(systemName: state.badgeSymbol)
                .font(.system(size: 8 * scale, weight: .bold))
                .foregroundStyle(.white)
                .padding(2 * scale)
                .background(macBuddyColor(state.accent), in: Circle())
                .offset(x: 5 * scale, y: -5 * scale)
        }
        .frame(height: 22 * scale)
        .animation(.smooth, value: state)
    }
}

/// Mac color mapping for the shared `BuddyAccent` (kept identical to iOS).
func macBuddyColor(_ accent: BuddyAccent) -> Color {
    switch accent {
    case .alert:     .orange
    case .curious:   .blue
    case .impatient: .pink
    case .busy:      .blue
    case .worry:     .red
    case .good:      .green
    case .calm:      .gray
    }
}
