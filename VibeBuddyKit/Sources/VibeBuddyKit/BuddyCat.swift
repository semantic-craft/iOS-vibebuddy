import SwiftUI

/// The buddy: the white cat from the app icon, drawn entirely in code so every
/// surface (iPhone header, Dynamic Island, widget, Watch, Mac glance and
/// dashboard, menu bar) renders the same character from one geometry
/// (ADR-0007, second amendment).
///
/// Colour has two channels that never share a value:
/// - `accent` is the identity colour (inner ears, belly). It is sampled from the
///   app icon and is the *one* constant to change if the brand colour moves.
/// - The eyes carry the status colour, and only for the states that need
///   attention (`requiresInput`, `thinking`, `error` tokens). Everything else
///   on the face is `ink`, so the character never depends on the accent.
public enum BuddyCat {
    /// Body fill — the icon's white.
    public static let body = Color(.sRGB, red: 0xEC / 255, green: 0xF0 / 255, blue: 0xF9 / 255, opacity: 1)
    /// Identity accent (inner ears, belly). Sampled from the app icon.
    public static let accent = Color(.sRGB, red: 0x8A / 255, green: 0xC3 / 255, blue: 0x7E / 255, opacity: 1)
    /// Facial ink (resting eyes, mouth, open-mouth cavity, light-ground shadow).
    public static let ink = Color(.sRGB, red: 0x44 / 255, green: 0x55 / 255, blue: 0x71 / 255, opacity: 1)
    /// Closed-eye lines and the sleeping "z".
    public static let lid = Color(.sRGB, red: 0x9A / 255, green: 0xA6 / 255, blue: 0xBC / 255, opacity: 1)

    /// Below this width the body and mouth are dropped and only the head is drawn.
    public static let bodyThreshold: CGFloat = 34
    /// Below this width the mouth is dropped as well (head, ears, eyes only).
    public static let mouthThreshold: CGFloat = 28

    /// Unit canvas: 52 × 60 with the body, 46 × 46 for the head alone.
    public static func height(forWidth width: CGFloat, showsBody: Bool) -> CGFloat {
        showsBody ? width * 60 / 52 : width
    }

    public enum Mood: String, Sendable, Equatable, CaseIterable {
        case calm      // idle — a plain cat, no status colour
        case working   // thinking
        case alert     // approval / question — ears up, eyes wide
        case wait      // long wait — ears up, eyes half-lidded
        case worry     // stuck — ears flattened, frown
        case happy     // done — closed happy arcs
        case sleep     // no sessions — loaf, eyes shut
    }
}

/// One frame of the cat. Platform views own the clock (blink, mouth flap, bob)
/// and pass the frame's `speaking` / `blink` in; Watch, widget and Live
/// Activity render it static.
public struct BuddyCatFace: View {
    public var mood: BuddyCat.Mood
    /// This frame shows the open mouth (the caller toggles it while speaking).
    public var speaking: Bool
    /// Ears up plus a ring around the sprite.
    public var listening: Bool
    /// This frame shows closed eyes.
    public var blink: Bool
    /// Draw the body and belly under the head (52 × 60); off → head only (46 × 46).
    public var showsBody: Bool
    public var showsMouth: Bool
    /// A 1 pt ink shadow so the white cat separates from a light card.
    public var shadow: Bool
    /// The listening ring is body-white on dark surfaces, ink on light ones.
    public var onDark: Bool
    /// Template silhouette: one colour, no accent, eyes punched to transparent.
    public var monochrome: Bool

    public init(mood: BuddyCat.Mood,
                speaking: Bool = false,
                listening: Bool = false,
                blink: Bool = false,
                showsBody: Bool = true,
                showsMouth: Bool = true,
                shadow: Bool = false,
                onDark: Bool = false,
                monochrome: Bool = false) {
        self.mood = mood
        self.speaking = speaking
        self.listening = listening
        self.blink = blink
        self.showsBody = showsBody
        self.showsMouth = showsMouth
        self.shadow = shadow
        self.onDark = onDark
        self.monochrome = monochrome
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            draw(&ctx, size: size)
        }
        .shadow(color: shadow && !monochrome ? BuddyCat.ink.opacity(0.28) : .clear,
                radius: shadow ? 1 : 0, y: shadow ? 1 : 0)
        .accessibilityHidden(true)
    }

    // MARK: drawing (unit space: 52 × 60, or the head's 46 × 46 window at x 3…49)

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        if showsBody {
            ctx.scaleBy(x: size.width / 52, y: size.height / 60)
        } else {
            ctx.scaleBy(x: size.width / 46, y: size.height / 46)
            ctx.translateBy(x: -3, y: 0)
        }

        let sleep = mood == .sleep
        let fur: Color = monochrome ? .black : BuddyCat.body
        let ink: Color = BuddyCat.ink
        let dy: CGFloat = sleep ? 7 : 0

        // Ears (drawn first; their bases hide under the head).
        let perk = listening || mood == .alert || mood == .wait
        let outer: Ear, inner: Ear
        switch (mood, perk) {
        case (.worry, _):
            outer = Ear(base: (5, 26), c1: (0.5, 19), tip: (2.5, 13.5), c2: (4.5, 11), end: (22, 12))
            inner = Ear(base: (7.8, 23), c1: (4.8, 18.5), tip: (6, 15.5), c2: (7.4, 14), end: (17.5, 13.8))
        case (_, true):
            outer = Ear(base: (8.5, 21), c1: (7, 6), tip: (10, 2.8), c2: (12.6, 1.4), end: (23, 9))
            inner = Ear(base: (10.6, 18.5), c1: (10, 8.5), tip: (11.8, 6.2), c2: (13.4, 5.4), end: (18.6, 10))
        default:
            outer = Ear(base: (7, 22), c1: (6, 8.5), tip: (10.5, 5), c2: (14, 3.8), end: (24, 10.5))
            inner = Ear(base: (9.6, 19.2), c1: (9.6, 10.4), tip: (12.2, 8.2), c2: (14.4, 7.4), end: (18.8, 10.8))
        }
        for mirrored in [false, true] {
            let p = outer.path(mirrored: mirrored, dy: dy)
            ctx.fill(p, with: .color(fur))
            ctx.stroke(p, with: .color(fur), style: StrokeStyle(lineWidth: 3.2, lineJoin: .round))
        }

        // Head.
        ctx.fill(ellipse(26, sleep ? 32 : 28.5, sleep ? 20.5 : 20.5, sleep ? 16 : 18), with: .color(fur))

        if !monochrome {
            for mirrored in [false, true] {
                let p = inner.path(mirrored: mirrored, dy: dy)
                ctx.fill(p, with: .color(BuddyCat.accent))
                ctx.stroke(p, with: .color(BuddyCat.accent), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            }
            if showsBody {
                if sleep {
                    ctx.fill(ellipse(26, 48, 23, 11), with: .color(fur))
                } else {
                    ctx.fill(ellipse(26, 49.5, 17.5, 10.5), with: .color(fur))
                    ctx.fill(ellipse(26, 53.2, 8.5, 4.8), with: .color(BuddyCat.accent))
                }
            }
        }

        // Eyes.
        let cy: CGFloat = sleep ? 31 : 29
        let eye = BuddyCat.eyeColor(for: mood)
        for cx in [17.5, 34.5] as [CGFloat] {
            if monochrome {
                ctx.blendMode = .destinationOut
                ctx.fill(ellipse(cx, cy, 3.4, 4.4), with: .color(.black))
                ctx.blendMode = .normal
                continue
            }
            if sleep || blink {
                var p = Path()
                p.move(to: CGPoint(x: cx - 3.2, y: cy - 0.3))
                p.addQuadCurve(to: CGPoint(x: cx + 3.2, y: cy - 0.3), control: CGPoint(x: cx, y: cy + 2.1))
                ctx.stroke(p, with: .color(BuddyCat.lid), style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
                continue
            }
            if mood == .happy {
                var p = Path()
                p.move(to: CGPoint(x: cx - 3.6, y: cy + 1.2))
                p.addQuadCurve(to: CGPoint(x: cx + 3.6, y: cy + 1.2), control: CGPoint(x: cx, y: cy - 3.8))
                ctx.stroke(p, with: .color(eye), style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                continue
            }
            let wide = mood == .alert
            ctx.fill(ellipse(cx, cy, wide ? 3.9 : 3.3, wide ? 4.9 : 4.3), with: .color(eye))
            if mood == .wait {
                // A lid over the top of the eye: half-open, unimpressed.
                var p = Path()
                p.move(to: CGPoint(x: cx - 4.4, y: cy - 5.4))
                p.addLine(to: CGPoint(x: cx + 4.4, y: cy - 5.4))
                p.addLine(to: CGPoint(x: cx + 4.4, y: cy - 1.2))
                p.addQuadCurve(to: CGPoint(x: cx - 4.4, y: cy - 1.2), control: CGPoint(x: cx, y: cy + 0.4))
                p.closeSubpath()
                ctx.fill(p, with: .color(fur))
            } else if mood == .worry {
                // A slanted lid: the outer corners droop.
                let left = cx < 26
                var p = Path()
                p.move(to: CGPoint(x: cx - 4.2, y: cy - 5.2))
                p.addLine(to: CGPoint(x: cx + 4.2, y: cy - 5.2))
                p.addLine(to: CGPoint(x: cx + 4.2, y: cy - 3))
                p.addQuadCurve(to: CGPoint(x: cx - 4.2, y: cy - 3 + (left ? 0 : 3)),
                               control: CGPoint(x: cx, y: cy - 3 + (left ? 2.4 : -0.6)))
                p.closeSubpath()
                ctx.fill(p, with: .color(fur))
            }
        }

        // Mouth.
        if !monochrome, !sleep, showsMouth {
            if speaking {
                ctx.fill(ellipse(26, 38, 2.8, 2.3), with: .color(ink))
            } else {
                var p = Path()
                let width: CGFloat
                switch mood {
                case .worry:
                    p.move(to: CGPoint(x: 22.6, y: 38.8))
                    p.addQuadCurve(to: CGPoint(x: 29.4, y: 38.8), control: CGPoint(x: 26, y: 36))
                    width = 1.6
                case .happy:
                    p.move(to: CGPoint(x: 21.4, y: 36))
                    p.addQuadCurve(to: CGPoint(x: 26, y: 36), control: CGPoint(x: 23.7, y: 39.4))
                    p.addQuadCurve(to: CGPoint(x: 30.6, y: 36), control: CGPoint(x: 28.3, y: 39.4))
                    width = 1.8
                default:
                    p.move(to: CGPoint(x: 22.4, y: 36.4))
                    p.addQuadCurve(to: CGPoint(x: 26, y: 36.4), control: CGPoint(x: 24.2, y: 39))
                    p.addQuadCurve(to: CGPoint(x: 29.6, y: 36.4), control: CGPoint(x: 27.8, y: 39))
                    width = 1.6
                }
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }

        // Sleeping: two small z's off the right ear.
        if sleep, !monochrome {
            var z = Path()
            z.move(to: CGPoint(x: 40, y: 9)); z.addLine(to: CGPoint(x: 44.5, y: 9))
            z.addLine(to: CGPoint(x: 40, y: 14.5)); z.addLine(to: CGPoint(x: 44.5, y: 14.5))
            z.move(to: CGPoint(x: 45.5, y: 3)); z.addLine(to: CGPoint(x: 48.5, y: 3))
            z.addLine(to: CGPoint(x: 45.5, y: 6.5)); z.addLine(to: CGPoint(x: 48.5, y: 6.5))
            ctx.stroke(z, with: .color(BuddyCat.lid), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }

        // Listening ring.
        if listening, !monochrome {
            let rect = showsBody ? CGRect(x: 1.5, y: 1.5, width: 49, height: 57)
                                 : CGRect(x: 4.5, y: 1.5, width: 43, height: 43)
            let ring = Path(roundedRect: rect, cornerRadius: showsBody ? 9 : 8, style: .continuous)
            ctx.stroke(ring, with: .color((onDark ? BuddyCat.body : ink).opacity(0.8)), lineWidth: 2)
        }
    }

    private func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    /// One ear as a rounded wedge: base → (curve) tip → (curve) end, closed under
    /// the head. `mirrored` flips it across the face's centre line.
    private struct Ear {
        let base, c1, tip, c2, end: (CGFloat, CGFloat)
        func path(mirrored: Bool, dy: CGFloat) -> Path {
            func pt(_ p: (CGFloat, CGFloat)) -> CGPoint {
                CGPoint(x: mirrored ? 52 - p.0 : p.0, y: p.1 + dy)
            }
            var p = Path()
            p.move(to: pt(base))
            p.addQuadCurve(to: pt(tip), control: pt(c1))
            p.addQuadCurve(to: pt(end), control: pt(c2))
            p.closeSubpath()
            return p
        }
    }
}
