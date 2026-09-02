import SwiftUI
import VibeBuddyKit

/// A static pixel black-and-white cat for the Live Activity / Dynamic Island,
/// matching the in-app iOS `PetFace` (ADR-0007). A light body on the activity's
/// dark surface, with the shared task status accent in the eyes; state shows in the ears
/// (alert ears-up) and an idle-curl loaf. The extension links VibeBuddyKit so
/// this rendering consumes the same presentation state and exact color tokens.
struct ActivityPixelCat: View {
    let state: TaskPresentationState
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
        if state == .idle || state == .unassigned { return Self.sleeping }
        let ears: [String]
        if state == .requiresInput { ears = Self.alertEars }
        else if state == .error { ears = Self.worryEars }
        else { ears = Self.calmEars }
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
        case "#":      return .white                 // light cat on the dark activity surface
        case "o", "O": return Color(taskStatus: state.colorToken)
        case "-":      return .white.opacity(0.5)     // closed / sleeping eyes
        default:       return nil
        }
    }
}

/// Build the shared tap-target deep link for the Widget and Live Activity.
func activitySessionURL(id: String) -> URL? {
    VibeBuddyDeepLink.sessionURL(id: id)
}
