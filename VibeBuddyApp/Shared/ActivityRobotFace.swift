import SwiftUI

/// The buddy's mood for the Live Activity, derived purely from the live counts.
/// Kept self-contained (no VibeBuddyKit) so the widget extension stays lean.
enum ActivityMood {
    case needsYou   // something needs a response — alert
    case working    // sessions running, nothing waiting — focused
    case done       // only completed sessions — happy
    case idle       // nothing going on — resting

    static func from(needsResponse: Int, working: Int, done: Int) -> ActivityMood {
        if needsResponse > 0 { return .needsYou }
        if working > 0 { return .working }
        if done > 0 { return .done }
        return .idle
    }

    var accent: Color {
        switch self {
        case .needsYou: .orange
        case .working:  .blue
        case .done:     .green
        case .idle:     .secondary
        }
    }
}

/// A tiny code-drawn robot head for the Live Activity / Dynamic Island, matching
/// the in-app `PetFace` vocabulary (alert eyes when you're needed, a smile when
/// done) but static and dependency-free — see ADR-0006 (all-code-drawn pet, no
/// bundled artwork → App-Store-review-safe by construction).
struct ActivityRobotFace: View {
    let mood: ActivityMood
    var size: CGFloat = 38

    private var accent: Color { mood.accent }

    var body: some View {
        VStack(spacing: 1) {
            // antenna
            Capsule().fill(accent).frame(width: 2, height: size * 0.12)
                .overlay(alignment: .top) {
                    Circle().fill(accent).frame(width: size * 0.1, height: size * 0.1)
                        .offset(y: -size * 0.07)
                }
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .stroke(accent, lineWidth: 1.6))
                VStack(spacing: size * 0.1) {
                    HStack(spacing: size * 0.16) { eye; eye }
                    mouth
                }
                .foregroundStyle(accent)
            }
            .frame(width: size, height: size * 0.82)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var eye: some View {
        switch mood {
        case .needsYou:                       // wide, alert
            Circle().frame(width: size * 0.18, height: size * 0.18)
        case .done:                           // happy ^ ^
            RobotArc().stroke(accent, style: .init(lineWidth: 1.8, lineCap: .round))
                .frame(width: size * 0.2, height: size * 0.12)
        case .idle:                           // closed — —
            Capsule().frame(width: size * 0.2, height: size * 0.05)
        case .working:                        // neutral
            Capsule().frame(width: size * 0.12, height: size * 0.18)
        }
    }

    @ViewBuilder private var mouth: some View {
        switch mood {
        case .done:
            RobotArc().stroke(accent, style: .init(lineWidth: 1.8, lineCap: .round))
                .frame(width: size * 0.28, height: size * 0.12)
        case .needsYou:
            Capsule().frame(width: size * 0.26, height: size * 0.06)
        case .working:
            Capsule().frame(width: size * 0.2, height: size * 0.06)
        case .idle:
            Circle().frame(width: size * 0.08, height: size * 0.08)
        }
    }
}

/// Smile arc (concave-up). Mirrors the private `Arc` in `PetFace`.
private struct RobotArc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                       control: CGPoint(x: rect.midX, y: rect.minY))
        return p
    }
}

/// Build the tap-target deep link for the widget. Kit-free mirror of
/// `VibeBuddyDeepLink.sessionURL` in VibeBuddyKit — the exact string form is
/// pinned by `DeepLinkTests` so the two stay in sync.
func activitySessionURL(id: String) -> URL? {
    var components = URLComponents()
    components.scheme = "vibebuddy"
    components.host = "session"
    components.queryItems = [URLQueryItem(name: "id", value: id)]
    return components.url
}
