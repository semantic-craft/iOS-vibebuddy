import SwiftUI
import VibeBuddyKit

/// A Stack-chan-inspired expressive face, drawn entirely with SwiftUI shapes (no
/// third-party art → App-Store-clean). Eyes blink and gaze; the expression
/// follows the buddy's mood; the mouth animates while the companion is speaking.
struct PetFace: View {
    let state: BuddyState
    var speaking: Bool = false
    var listening: Bool = false

    @State private var blink = false
    @State private var gaze: CGFloat = 0      // -1 … 1 horizontal look
    @State private var mouthOpen: CGFloat = 0

    private var accent: Color { buddyColor(state.accent) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(accent.opacity(listening ? 0.9 : 0.3), lineWidth: listening ? 3 : 2))

            VStack(spacing: 7) {
                HStack(spacing: 12) {
                    eye
                    eye
                }
                mouth
            }
            .foregroundStyle(accent)
            .offset(x: gaze * 4)
        }
        .frame(width: 58, height: 52)
        .onAppear { startIdle() }
        .onChange(of: speaking) { _, on in if on { startTalking() } else { mouthOpen = 0 } }
        .accessibilityHidden(true)
    }

    // MARK: eyes

    @ViewBuilder private var eye: some View {
        switch state {
        case .done:                       // happy ^ ^
            Arc().stroke(accent, style: .init(lineWidth: 3, lineCap: .round))
                .frame(width: 12, height: 8)
        case .sleeping:                   // closed — —
            Capsule().frame(width: 12, height: 3)
        case .stuck, .approval:           // wide, alert
            Circle().frame(width: 12, height: 12)
                .scaleEffect(y: blink ? 0.1 : 1, anchor: .center)
        default:                          // normal, blinking
            Capsule().frame(width: 11, height: blink ? 2 : 11)
        }
    }

    // MARK: mouth — expression + talking

    @ViewBuilder private var mouth: some View {
        switch state {
        case .done:
            Arc().stroke(accent, style: .init(lineWidth: 2.5, lineCap: .round))
                .frame(width: 16, height: 8)
        case .stuck:
            Arc().stroke(accent, style: .init(lineWidth: 2.5, lineCap: .round))
                .frame(width: 14, height: 7).rotationEffect(.degrees(180))   // worried frown
        case .sleeping:
            Circle().frame(width: 5, height: 5)                              // small o (Zzz vibe)
        default:
            Capsule()
                .frame(width: 14, height: 3 + mouthOpen * 7)                 // opens while talking
        }
    }

    // MARK: behaviours

    private func startIdle() {
        // Slow blink loop.
        withAnimation(.easeInOut(duration: 0.12).repeatForever().delay(2.6)) { blink = true }
        // Wander the gaze a little so it feels alive.
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { gaze = 1 }
    }

    private func startTalking() {
        withAnimation(.easeInOut(duration: 0.16).repeatForever(autoreverses: true)) { mouthOpen = 1 }
    }
}

/// A simple smile/frown arc (concave-up by default).
private struct Arc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                       control: CGPoint(x: rect.midX, y: rect.minY))
        return p
    }
}
