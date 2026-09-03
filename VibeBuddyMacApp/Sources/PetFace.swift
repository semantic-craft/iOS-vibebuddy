import SwiftUI
import VibeBuddyKit

/// The Mac buddy: the **same pixel black-and-white cat as iOS** (ADR-0007,
/// amended — the pet is a cat on *both* platforms now). Drawn entirely in code
/// (SwiftUI `Canvas`, a 13-wide pixel grid), so zero bundled art. The body is
/// `Color.primary` on a card and white in `bare` mode (the dark notch glance);
/// the eyes carry the status accent. Ears + eyes change with mood, the muzzle
/// flaps while the companion speaks, and the ears perk + a tinted ring shows
/// while it listens — the same sprite the iPhone shows in-app.
struct PetFace: View {
    let state: BuddyState
    var speaking: Bool = false
    var listening: Bool = false
    var bare: Bool = false
    var scale: CGFloat = 1

    @Environment(\.displayScale) private var displayScale

    private var accent: Color { Color(taskStatus: state.presentationState.colorToken) }
    private var ink: Color { bare ? .white : .primary }

    private enum Mood { case calm, alert, worry, happy, sleep }
    private var mood: Mood {
        switch state {
        case .done:                 return .happy
        case .sleeping:             return .sleep
        case .idle:                 return .calm
        case .stuck:                return .worry
        case .approval, .question:  return .alert
        default:                    return .calm   // working, longWait
        }
    }

    var body: some View {
        // ~10 fps is plenty for the blink/talk animation and easy on the battery
        // (the glance is always on screen).
        TimelineView(.periodic(from: .now, by: 0.1)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let blink = mood != .sleep && t.truncatingRemainder(dividingBy: 3.2) < 0.13
            let mouthOpen = speaking && Int(t / 0.16) % 2 == 0
            Canvas { ctx, size in
                let grid = rows(blink: blink, mouthOpen: mouthOpen)
                let cw = size.width / 13
                let ch = size.height / CGFloat(grid.count)
                // Snap every cell edge to the display grid instead of padding each
                // rect by 0.6pt: shared edges land on the same device pixel, so the
                // sprite stays crisp (and seam-free) even at the small collapsed
                // glance size, where a cell is only ~1.5pt wide.
                let dp = max(displayScale, 1)
                func snap(_ v: CGFloat) -> CGFloat { (v * dp).rounded() / dp }
                for (r, line) in grid.enumerated() {
                    let y0 = snap(CGFloat(r) * ch), y1 = snap(CGFloat(r + 1) * ch)
                    for (c, char) in line.enumerated() {
                        guard let color = fill(char) else { continue }
                        let x0 = snap(CGFloat(c) * cw), x1 = snap(CGFloat(c + 1) * cw)
                        let rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                        ctx.fill(Path(rect), with: .color(color))
                    }
                }
            }
            .frame(width: 50 * scale, height: 58 * scale)
            .offset(y: speaking ? CGFloat(sin(t * 11)) * 0.8 * scale : 0)
            .overlay {
                if listening {
                    RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                        .stroke(accent.opacity(0.8), lineWidth: 2 * scale)
                }
            }
        }
        .frame(width: 54 * scale, height: 60 * scale)
        .background {
            if !bare {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: pixel rows (13 wide) — identical sprite to the iOS `PetFace`.

    private func rows(blink: Bool, mouthOpen: Bool) -> [String] {
        if mood == .sleep { return Self.sleeping }
        let eyesOpen = !blink
        let ears = (listening || mood == .alert) ? Self.alertEars
                 : (mood == .worry ? Self.worryEars : Self.calmEars)
        let eyeRow = eyesOpen ? "#.o#.....#o.#" : "#.-#.....#-.#"
        let mouthRow = mouthOpen ? "####.....####" : "#####.#.#####"
        return ears + [
            ".###########.",
            "#############",
            eyeRow,
            mouthRow,
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
    private static let worryEars = ["#...........#", "##.........##"]

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
        case "#":      return ink                       // black on a card, white on the glance
        case "o", "O": return accent                    // status colour in the eyes
        case "-":      return bare ? .white.opacity(0.5) : .secondary   // closed / sleeping eyes
        default:       return nil                        // "." → empty (and open-mouth gap)
        }
    }
}
