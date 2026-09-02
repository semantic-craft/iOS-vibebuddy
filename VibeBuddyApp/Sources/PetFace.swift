import SwiftUI
import VibeBuddyKit

/// The iOS buddy: a pixel black-and-white cat, drawn entirely in code (no bundled
/// art → App-Store-clean, see ADR-0007). The body is `Color.primary` so it reads
/// as a black silhouette in light mode and white in dark; the eyes carry the
/// status accent colour. Ears + eyes change with mood; the muzzle flaps while the
/// companion speaks; the ears perk and a tinted ring shows while it listens.
///
/// Mac keeps the robot `PetFace`; only iOS is the cat (ADR-0007).
struct PetFace: View {
    let state: BuddyState
    var speaking: Bool = false
    var listening: Bool = false

    private var accent: Color { Color(taskStatus: state.presentationState.colorToken) }

    private enum Mood { case calm, alert, worry, happy, sleep }
    private var mood: Mood {
        switch state {
        case .done:                       return .happy
        case .sleeping:                   return .sleep
        case .idle:                       return .calm
        case .stuck:                      return .worry
        case .approval, .question:        return .alert
        default:                          return .calm   // working, longWait
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let blink = t.truncatingRemainder(dividingBy: 3.2) < 0.13
            let mouthOpen = speaking && Int(t / 0.16) % 2 == 0
            Canvas { ctx, size in
                let grid = rows(blink: blink, mouthOpen: mouthOpen)
                let cw = size.width / 13
                let ch = size.height / CGFloat(grid.count)
                for (r, line) in grid.enumerated() {
                    for (c, char) in line.enumerated() {
                        guard let color = fill(char) else { continue }
                        let rect = CGRect(x: CGFloat(c) * cw, y: CGFloat(r) * ch,
                                          width: cw + 0.6, height: ch + 0.6)
                        ctx.fill(Path(rect), with: .color(color))
                    }
                }
            }
            .frame(width: 52, height: 60)
            .overlay {
                if listening {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(accent.opacity(0.8), lineWidth: 2)
                }
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: pixel rows (13 wide)

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
        case "#":      return .primary       // black in light mode, white in dark
        case "o", "O": return accent          // status colour in the eyes
        case "-":      return .secondary      // closed / sleeping eyes
        default:       return nil             // "." → empty (and open-mouth gap)
        }
    }
}
