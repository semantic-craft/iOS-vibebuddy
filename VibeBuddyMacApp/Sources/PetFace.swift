import SwiftUI
import VibeBuddyKit

/// An ASCII-art robot pet in the style of Claude Code's `/buddy` companions: a
/// small monospaced sprite drawn purely from text (zero third-party art). It
/// feels alive — blinks and bobs when idle, opens its mouth while the companion
/// talks, perks its antenna while listening, and changes eyes/mouth with the
/// mood. `bare` mode (the dark glance) draws it white; otherwise on a card.
struct PetFace: View {
    let state: BuddyState
    var speaking: Bool = false
    var listening: Bool = false
    var bare: Bool = false
    var scale: CGFloat = 1

    private var tint: Color { bare ? .white : macBuddyColor(state.accent) }
    private var sleeping: Bool { state == .sleeping }

    var body: some View {
        // ~10 fps is plenty for ASCII animation and easy on the battery (the
        // glance is always on screen).
        TimelineView(.periodic(from: .now, by: 0.1)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Text(sprite(t: t))
                .font(.system(size: 10 * scale, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .multilineTextAlignment(.center)
                .lineSpacing(1)
                .fixedSize()
                .offset(y: speaking ? CGFloat(sin(t * 11)) * 0.8 * scale : 0)
        }
        .frame(width: 54 * scale, height: 50 * scale)
        .background {
            if !bare {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    /// Build the 5-line robot sprite for the current mood + animation phase.
    private func sprite(t: TimeInterval) -> String {
        let blink = !sleeping && t.truncatingRemainder(dividingBy: 3.0) < 0.16
        let eyes = blink ? "- -" : eyesFor(state)
        let mouth = mouthFor(t: t)
        let ant = antenna(t: t)
        return [
            ant,
            "╭───╮",
            "│\(eyes)│",
            "│ \(mouth) │",
            "╰┴─┴╯",
        ].joined(separator: "\n")
    }

    private func eyesFor(_ s: BuddyState) -> String {
        switch s {
        case .done:                 return "^ ^"   // happy
        case .sleeping:             return "- -"   // closed
        case .stuck:                return "x x"   // ouch
        case .approval, .question:  return "O O"   // wide, curious
        case .longWait:             return "u u"   // bored
        case .working:              return "o o"   // alert
        }
    }

    private func mouthFor(t: TimeInterval) -> String {
        if speaking {
            switch Int(t * 7) % 3 {
            case 0:  return "-"
            case 1:  return "o"
            default: return "O"
            }
        }
        switch state {
        case .done:                 return "u"   // smile
        case .stuck:                return "n"   // frown
        case .sleeping:             return "."   // quiet
        case .approval, .question:  return "o"
        default:                    return "-"
        }
    }

    private func antenna(t: TimeInterval) -> String {
        if listening { return Int(t * 4) % 2 == 0 ? "╹" : "╷" }  // perk/twitch
        return "╷"
    }
}
