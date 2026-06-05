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

/// A static pixel black-and-white cat for the Live Activity / Dynamic Island,
/// matching the in-app iOS `PetFace` (ADR-0007). A light body on the activity's
/// dark surface, with the status accent in the eyes; mood shows in the ears
/// (alert ears-up) and an idle-curl loaf. Code-drawn, dependency-free — the
/// widget extension deliberately doesn't link VibeBuddyKit.
struct ActivityPixelCat: View {
    let mood: ActivityMood
    var size: CGFloat = 40

    var body: some View {
        Canvas { ctx, sz in
            let grid = rows
            let cw = sz.width / 13
            let ch = sz.height / CGFloat(grid.count)
            for (r, line) in grid.enumerated() {
                for (c, char) in line.enumerated() {
                    guard let color = fill(char) else { continue }
                    let rect = CGRect(x: CGFloat(c) * cw, y: CGFloat(r) * ch,
                                      width: cw + 0.5, height: ch + 0.5)
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: size, height: size * 60 / 52)
        .accessibilityHidden(true)
    }

    private var rows: [String] {
        if mood == .idle { return Self.sleeping }
        let ears = mood == .needsYou ? Self.alertEars : Self.calmEars
        return ears + [
            ".###########.",
            "#############",
            "#.o#.....#o.#",
            "#####.#.#####",
            "#############",
            ".###########.",
            ".###########.",
            ".###########.",
            ".###########.",
            ".####...####.",
            ".###########.",
            "#####...#####",
            "..........##.",
        ]
    }

    private static let calmEars  = [".##.......##.", ".###.....###."]
    private static let alertEars = ["#.#.......#.#", "#.#.......#.#"]
    private static let sleeping = [
        ".............",
        "...#######...",
        "..#########..",
        ".###########.",
        ".###########.",
        ".#--.....--#.",
        ".###########.",
        ".###########.",
        ".###########.",
        "..#########..",
        "...#######...",
        ".....###.....",
        ".............",
        ".............",
        ".............",
    ]

    private func fill(_ char: Character) -> Color? {
        switch char {
        case "#":      return .white                 // light cat on the dark activity surface
        case "o", "O": return mood.accent            // status colour in the eyes
        case "-":      return .white.opacity(0.5)     // closed / sleeping eyes
        default:       return nil
        }
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
