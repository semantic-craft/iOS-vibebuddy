import SwiftUI
import VibeBuddyKit

/// A Stack-chan-inspired expressive face for the Mac, drawn entirely with SwiftUI
/// shapes (matches the iOS buddy). `bare` mode (for the dark glance) drops the
/// card background and draws features in white; `card` mode suits the dashboard.
struct PetFace: View {
    let state: BuddyState
    var speaking: Bool = false
    var listening: Bool = false
    var bare: Bool = false
    var scale: CGFloat = 1

    @State private var blink = false
    @State private var gaze: CGFloat = 0
    @State private var mouthOpen: CGFloat = 0

    private var accent: Color { bare ? .white : macBuddyColor(state.accent) }

    var body: some View {
        ZStack {
            if !bare {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(macBuddyColor(state.accent).opacity(listening ? 0.9 : 0.3),
                                lineWidth: listening ? 3 : 2))
            }
            VStack(spacing: 6 * scale) {
                HStack(spacing: 11 * scale) { eye; eye }
                mouth
            }
            .foregroundStyle(accent)
            .offset(x: gaze * 4)
        }
        .frame(width: 54 * scale, height: 48 * scale)
        .onAppear { startIdle() }
        .onChange(of: speaking) { _, on in if on { startTalking() } else { mouthOpen = 0 } }
    }

    @ViewBuilder private var eye: some View {
        switch state {
        case .done:
            Arc().stroke(accent, style: .init(lineWidth: 2.5, lineCap: .round)).frame(width: 11 * scale, height: 7 * scale)
        case .sleeping:
            Capsule().frame(width: 11 * scale, height: 3 * scale)
        case .stuck, .approval:
            Circle().frame(width: 11 * scale, height: 11 * scale).scaleEffect(y: blink ? 0.1 : 1)
        default:
            Capsule().frame(width: 10 * scale, height: (blink ? 2 : 10) * scale)
        }
    }

    @ViewBuilder private var mouth: some View {
        switch state {
        case .done:
            Arc().stroke(accent, style: .init(lineWidth: 2.5, lineCap: .round)).frame(width: 15 * scale, height: 7 * scale)
        case .stuck:
            Arc().stroke(accent, style: .init(lineWidth: 2.5, lineCap: .round)).frame(width: 13 * scale, height: 6 * scale)
                .rotationEffect(.degrees(180))
        case .sleeping:
            Circle().frame(width: 4 * scale, height: 4 * scale)
        default:
            Capsule().frame(width: 13 * scale, height: (3 + mouthOpen * 6) * scale)
        }
    }

    private func startIdle() {
        withAnimation(.easeInOut(duration: 0.12).repeatForever().delay(2.6)) { blink = true }
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { gaze = 1 }
    }
    private func startTalking() {
        withAnimation(.easeInOut(duration: 0.16).repeatForever(autoreverses: true)) { mouthOpen = 1 }
    }
}

private struct Arc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                       control: CGPoint(x: rect.midX, y: rect.minY))
        return p
    }
}
