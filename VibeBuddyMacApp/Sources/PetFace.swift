import SwiftUI
import VibeBuddyKit

/// The buddy: "Mochi", a cute orange-and-white (橘白) tabby, drawn procedurally
/// with `Canvas` (original art, zero third-party licensing) and animated with a
/// `TimelineView` so it feels alive: it breathes and blinks when idle, its mouth
/// lip-syncs while the companion talks, it tilts its head while listening, and
/// its eyes/mouth change with the mood.
struct PetFace: View {
    let state: BuddyState
    var speaking: Bool = false
    var listening: Bool = false
    var bare: Bool = false
    var scale: CGFloat = 1

    private var accent: Color { macBuddyColor(state.accent) }

    // Mochi's palette
    private let head   = Color(red: 0.957, green: 0.631, blue: 0.306)
    private let belly  = Color(red: 1.0,   green: 0.965, blue: 0.925)
    private let inner  = Color(red: 0.969, green: 0.663, blue: 0.678)
    private let stripe = Color(red: 0.851, green: 0.482, blue: 0.165)
    private let ink    = Color(red: 0.141, green: 0.122, blue: 0.133)
    private let nose   = Color(red: 0.914, green: 0.549, blue: 0.576)

    var body: some View {
        ZStack {
            if !bare {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            Circle().strokeBorder(accent, lineWidth: listening ? 3 : 0)
                .frame(width: 52 * scale, height: 52 * scale)
            TimelineView(.animation) { tl in
                Canvas { ctx, size in draw(ctx, size, t: tl.date.timeIntervalSinceReferenceDate) }
            }
            .frame(width: 50 * scale, height: 48 * scale)
            Circle().fill(accent).frame(width: 7 * scale, height: 7 * scale)
                .overlay(Circle().stroke(.white, lineWidth: 1))
                .offset(x: 19 * scale, y: -17 * scale)
        }
        .frame(width: 54 * scale, height: 50 * scale)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, t: TimeInterval) {
        var ctx = ctx
        let k = size.width / 110                     // SVG-ish 110-wide coordinate space
        // Procedural life.
        let breathe = 1 + 0.03 * sin(t * 2 * .pi / 3.0)
        let bc = t.truncatingRemainder(dividingBy: 4.2)
        let eyeOpen = (bc > 4.04 && bc < 4.17) ? 0.12 : 1.0          // quick blink
        let bobY = speaking ? -2.5 * abs(sin(t * 11)) : 0
        let tilt = listening ? 7 * sin(t * 3.4) : (state == .question ? 5 : 0)
        let mouthH = speaking ? (2 + 5 * abs(sin(t * 16))) : 2.0

        // Place + animate the whole cat around its centre (≈ 55,52 in this space).
        ctx.translateBy(x: size.width / 2, y: size.height / 2 + bobY * k)
        ctx.rotate(by: .degrees(tilt))
        ctx.scaleBy(x: k * breathe, y: k * breathe)
        ctx.translateBy(x: -55, y: -52)

        func fillEllipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ c: Color, opacity: Double = 1) {
            ctx.opacity = opacity
            ctx.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)), with: .color(c))
            ctx.opacity = 1
        }
        func tri(_ pts: [CGPoint], _ c: Color) {
            var p = Path(); p.move(to: pts[0]); p.addLine(to: pts[1]); p.addLine(to: pts[2]); p.closeSubpath()
            ctx.fill(p, with: .color(c))
        }

        // ears
        tri([CGPoint(x: 33, y: 30), CGPoint(x: 28, y: 8), CGPoint(x: 50, y: 24)], head)
        tri([CGPoint(x: 34, y: 26), CGPoint(x: 32, y: 15), CGPoint(x: 43, y: 24)], inner)
        tri([CGPoint(x: 77, y: 30), CGPoint(x: 82, y: 8), CGPoint(x: 60, y: 24)], head)
        tri([CGPoint(x: 76, y: 26), CGPoint(x: 78, y: 15), CGPoint(x: 67, y: 24)], inner)

        // head + cream muzzle
        fillEllipse(55, 50, 34, 31, head)
        fillEllipse(55, 61, 24, 18, belly)
        // forehead stripes
        for (dx, h) in [(-6.0, 5.0), (0.0, 7.0), (6.0, 5.0)] {
            ctx.fill(Path(roundedRect: CGRect(x: 55 + dx - 0.8, y: 26, width: 1.6, height: h),
                          cornerSize: CGSize(width: 0.8, height: 0.8)),
                     with: .color(stripe.opacity(0.8)))
        }
        // cheeks
        fillEllipse(35, 58, 5, 5, inner, opacity: 0.5)
        fillEllipse(75, 58, 5, 5, inner, opacity: 0.5)

        // eyes
        drawEye(&ctx, cx: 43, eyeOpen: eyeOpen)
        drawEye(&ctx, cx: 67, eyeOpen: eyeOpen)

        // nose + mouth
        tri([CGPoint(x: 52, y: 60), CGPoint(x: 58, y: 60), CGPoint(x: 55, y: 64)], nose)
        if state == .stuck {
            var f = Path(); f.move(to: CGPoint(x: 51, y: 72)); f.addQuadCurve(to: CGPoint(x: 59, y: 72), control: CGPoint(x: 55, y: 68))
            ctx.stroke(f, with: .color(ink), style: .init(lineWidth: 1.6, lineCap: .round))
        } else if state != .sleeping {
            ctx.fill(Path(roundedRect: CGRect(x: 52.5, y: 65, width: 5, height: mouthH),
                          cornerSize: CGSize(width: 1.5, height: 1.5)), with: .color(ink))
        }

        // whiskers
        ctx.stroke(whiskerPath(), with: .color(ink.opacity(0.4)), style: .init(lineWidth: 1.2, lineCap: .round))
    }

    private func drawEye(_ ctx: inout GraphicsContext, cx: Double, eyeOpen: Double) {
        let cy = 50.0
        switch state {
        case .done:   // happy ^
            var a = Path(); a.move(to: CGPoint(x: cx - 4.5, y: cy + 1)); a.addQuadCurve(to: CGPoint(x: cx + 4.5, y: cy + 1), control: CGPoint(x: cx, y: cy - 5))
            ctx.stroke(a, with: .color(ink), style: .init(lineWidth: 2.2, lineCap: .round))
        case .sleeping:   // closed —
            ctx.stroke(Path { $0.move(to: CGPoint(x: cx - 5, y: cy)); $0.addLine(to: CGPoint(x: cx + 5, y: cy)) },
                       with: .color(ink), style: .init(lineWidth: 2.2, lineCap: .round))
        default:
            let rx = (state == .stuck || state == .approval) ? 6.5 : 5.8
            let ry = ((state == .longWait) ? 7.0 : 9.0) * eyeOpen
            ctx.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)), with: .color(ink))
            if eyeOpen > 0.5 {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 3.6, y: cy - 4.4, width: 4.4, height: 4.4)), with: .color(.white))
                ctx.fill(Path(ellipseIn: CGRect(x: cx + 1.2, y: cy + 1.6, width: 2.2, height: 2.2)), with: .color(.white.opacity(0.85)))
            }
        }
    }

    private func whiskerPath() -> Path {
        var p = Path()
        for (x1, y1, x2, y2) in [(14.0, 56.0, 33.0, 58.0), (14.0, 64.0, 33.0, 62.0),
                                 (96.0, 56.0, 77.0, 58.0), (96.0, 64.0, 77.0, 62.0)] {
            p.move(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x2, y: y2))
        }
        return p
    }
}
