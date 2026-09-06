import SwiftUI

/// A `Shape` drawn from SVG path data (the `d` attribute), fitted and centred
/// in its rect. Understands M L H V C S Q T A Z in both cases, SVG's implicit
/// command repetition, and compact number runs like `.5.5` and `1-2`. The
/// agent brand marks ship as path strings so one drawing tints and scales the
/// same on iPhone, Watch, Mac and the widgets without an asset catalog.
public struct SVGPathShape: Shape {
    public let data: String
    public let viewBox: CGFloat

    public init(_ data: String, viewBox: CGFloat = 24) {
        self.data = data
        self.viewBox = viewBox
    }

    public func path(in rect: CGRect) -> Path {
        let unit = SVGPathParser.path(data)
        let scale = min(rect.width, rect.height) / viewBox
        let dx = rect.midX - viewBox * scale / 2
        let dy = rect.midY - viewBox * scale / 2
        return unit.applying(CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale))
    }
}

enum SVGPathParser {
    static func path(_ d: String) -> Path {
        var p = Path()
        var s = Scanner(d)
        var cmd: UInt8 = 0
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubicCtrl: CGPoint?, lastQuadCtrl: CGPoint?

        while true {
            s.skipSeparators()
            guard let b = s.peek() else { break }
            if isLetter(b) { cmd = b; s.advance() } else if cmd == 0 { break }
            let rel = cmd >= 97   // lowercase
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            var cubic: CGPoint?, quad: CGPoint?

            switch cmd | 0x20 {   // fold to lowercase
            case UInt8(ascii: "m"):
                guard let x = s.number(), let y = s.number() else { return p }
                cur = pt(x, y); start = cur; p.move(to: cur)
                cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")   // implicit pairs are linetos
            case UInt8(ascii: "l"):
                guard let x = s.number(), let y = s.number() else { return p }
                cur = pt(x, y); p.addLine(to: cur)
            case UInt8(ascii: "h"):
                guard let x = s.number() else { return p }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); p.addLine(to: cur)
            case UInt8(ascii: "v"):
                guard let y = s.number() else { return p }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); p.addLine(to: cur)
            case UInt8(ascii: "c"):
                guard let x1 = s.number(), let y1 = s.number(), let x2 = s.number(), let y2 = s.number(),
                      let x = s.number(), let y = s.number() else { return p }
                let c1 = pt(x1, y1), c2 = pt(x2, y2), end = pt(x, y)
                p.addCurve(to: end, control1: c1, control2: c2); cur = end; cubic = c2
            case UInt8(ascii: "s"):
                guard let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { return p }
                let c1 = lastCubicCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(x2, y2), end = pt(x, y)
                p.addCurve(to: end, control1: c1, control2: c2); cur = end; cubic = c2
            case UInt8(ascii: "q"):
                guard let x1 = s.number(), let y1 = s.number(), let x = s.number(), let y = s.number() else { return p }
                let c = pt(x1, y1), end = pt(x, y)
                p.addQuadCurve(to: end, control: c); cur = end; quad = c
            case UInt8(ascii: "t"):
                guard let x = s.number(), let y = s.number() else { return p }
                let c = lastQuadCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let end = pt(x, y)
                p.addQuadCurve(to: end, control: c); cur = end; quad = c
            case UInt8(ascii: "a"):
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(),
                      let large = s.flag(), let sweep = s.flag(),
                      let x = s.number(), let y = s.number() else { return p }
                let end = pt(x, y)
                addArc(&p, from: cur, to: end, rx: rx, ry: ry, rotationDegrees: rot, largeArc: large, sweep: sweep)
                cur = end
            case UInt8(ascii: "z"):
                p.closeSubpath(); cur = start
            default:
                return p
            }
            lastCubicCtrl = cubic
            lastQuadCtrl = quad
        }
        return p
    }

    private static func isLetter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }

    /// SVG arc → cubic Béziers (spec appendix F.6.5 centre parameterisation,
    /// then ≤90° segments).
    private static func addArc(_ p: inout Path, from p1: CGPoint, to p2: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDegrees: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        if p1 == p2 { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { p.addLine(to: p2); return }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (p1.x - p2.x) / 2, dy2 = (p1.y - p2.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = coef * -ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        var theta = theta1
        func map(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * px * cosPhi - ry * py * sinPhi,
                    y: cy + rx * px * sinPhi + ry * py * cosPhi)
        }
        for _ in 0..<segments {
            let theta2 = theta + step
            let c1 = cos(theta), s1 = sin(theta), c2 = cos(theta2), s2 = sin(theta2)
            p.addCurve(to: map(c2, s2),
                       control1: map(c1 - t * s1, s1 + t * c1),
                       control2: map(c2 + t * s2, s2 - t * c2))
            theta = theta2
        }
    }

    /// Byte cursor over the path data.
    private struct Scanner {
        let bytes: [UInt8]
        var i = 0
        init(_ s: String) { bytes = Array(s.utf8) }

        func peek() -> UInt8? { i < bytes.count ? bytes[i] : nil }
        mutating func advance() { i += 1 }
        mutating func skipSeparators() {
            while let b = peek(), b == 32 || b == 44 || b == 9 || b == 10 || b == 13 { i += 1 }
        }
        /// An arc flag is a single `0`/`1`, even when glued to the next number.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard let b = peek(), b == 48 || b == 49 else { return nil }
            i += 1
            return b == 49
        }
        mutating func number() -> CGFloat? {
            skipSeparators()
            let startIndex = i
            if let b = peek(), b == 43 || b == 45 { i += 1 }             // sign
            var sawDigit = false, sawDot = false
            while let b = peek() {
                if (48...57).contains(b) { sawDigit = true; i += 1 }
                else if b == 46 && !sawDot { sawDot = true; i += 1 }   // a second '.' starts the next number
                else { break }
            }
            if let b = peek(), b == 101 || b == 69 {                       // exponent
                let save = i
                i += 1
                if let s = peek(), s == 43 || s == 45 { i += 1 }
                var expDigits = false
                while let d = peek(), (48...57).contains(d) { expDigits = true; i += 1 }
                if !expDigits { i = save }
            }
            guard sawDigit, let value = Double(String(decoding: bytes[startIndex..<i], as: UTF8.self)) else {
                i = startIndex
                return nil
            }
            return CGFloat(value)
        }
    }
}
