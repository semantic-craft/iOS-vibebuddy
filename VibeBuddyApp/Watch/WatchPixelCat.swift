import SwiftUI
import VibeBuddyKit

/// The same pixel cat the iPhone, Live Activity, and Mac draw (ADR-0007), on a
/// 13-wide grid, entirely in code — no bundled artwork, no licensing risk.
///
/// The Watch version is deliberately static: a companion that blinks on the
/// wrist is motion nobody asked for, and a still cat needs no Reduce Motion
/// special case. The body is `.primary`; the eyes carry the status accent, so
/// the mood survives on a black-and-white silhouette.
struct WatchPixelCat: View {
    let state: BuddyState
    var size: CGSize = CGSize(width: 44, height: 51)

    private var accent: Color { Color(taskStatus: state.presentationState.colorToken) }

    private enum Mood { case calm, alert, worry, sleep }

    private var mood: Mood {
        switch state {
        case .sleeping:            return .sleep
        case .stuck:               return .worry
        case .approval, .question, .longWait: return .alert
        default:                   return .calm
        }
    }

    var body: some View {
        Canvas { context, size in
            let grid = rows
            let cellWidth = size.width / 13
            let cellHeight = size.height / CGFloat(grid.count)
            for (row, line) in grid.enumerated() {
                for (column, character) in line.enumerated() {
                    guard let color = fill(character) else { continue }
                    let rect = CGRect(x: CGFloat(column) * cellWidth,
                                      y: CGFloat(row) * cellHeight,
                                      width: cellWidth + 0.6, height: cellHeight + 0.6)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    private var rows: [String] {
        if mood == .sleep { return Self.sleeping }
        let ears: [String]
        switch mood {
        case .alert: ears = Self.alertEars
        case .worry: ears = Self.worryEars
        default:     ears = Self.calmEars
        }
        return ears + [
            ".###########.",
            "#############",
            "#.o#.....#o.#",
            "#####.#.#####",
            "#############",
            ".###########.",
            ".###########.",
            ".###########.",
            ".####...####.",
            ".###########.",
            "#####...#####",
        ]
    }

    private static let calmEars  = [".##.......##.", ".###.....###."]
    private static let alertEars = ["#.#.......#.#", "#.#.......#.#"]
    private static let worryEars = ["#...........#", "##.........##"]

    private static let sleeping = [
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
    ]

    private func fill(_ character: Character) -> Color? {
        switch character {
        case "#":      return .primary
        case "o":      return accent
        case "-":      return .secondary
        default:       return nil
        }
    }
}
