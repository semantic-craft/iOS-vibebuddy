import SwiftUI
import Testing
@testable import VibeBuddyKit

struct SVGPathShapeTests {
    /// Every agent's mark parses to a drawable path that stays inside its 24×24 box.
    @Test(arguments: AgentKind.allCases)
    func brandMarkParsesInsideViewBox(agent: AgentKind) {
        let path = SVGPathParser.path(agent.brandMark)
        #expect(!path.isEmpty)
        let box = path.boundingRect
        #expect(box.width > 8 && box.height > 8, "mark for \(agent) is too small: \(box)")
        #expect(box.minX >= -0.5 && box.minY >= -0.5 && box.maxX <= 24.5 && box.maxY <= 24.5,
                "mark for \(agent) leaves the box: \(box)")
    }

    /// Compact SVG syntax: implicit linetos after M, glued arc flags, `.5.5`
    /// number runs, and an arc — a circle of radius 5 around (12, 12).
    @Test func parsesCompactArcSyntax() {
        let d = "M7 12a5 5 0 1 0 10 0a5 5 0 1 0-10 0zM2 2 4 2 4 4zM.5.5h1v1h-1z"
        let path = SVGPathParser.path(d)
        let box = path.boundingRect
        #expect(abs(box.minX - 0.5) < 0.01 && abs(box.minY - 0.5) < 0.01)
        #expect(abs(box.maxX - 17) < 0.05 && abs(box.maxY - 17) < 0.05)
        // The circle's top: (12, 7) must lie on the path.
        #expect(path.contains(CGPoint(x: 12, y: 8)))
        #expect(!path.contains(CGPoint(x: 12, y: 18.5)))
    }

    /// The hand-drawn marks fill where they should under nonzero winding: the
    /// Grok ring is hollow except where the bar crosses; the OpenCode frame is
    /// hollow above its block and solid on the block.
    @Test func handDrawnMarksHaveTheRightHoles() {
        let grok = SVGPathParser.path(AgentKind.grok.brandMark)
        #expect(grok.contains(CGPoint(x: 12, y: 4)))       // ring
        #expect(grok.contains(CGPoint(x: 12, y: 12)))      // bar through the centre
        #expect(grok.contains(CGPoint(x: 16, y: 8)))       // bar inside the hole
        #expect(!grok.contains(CGPoint(x: 12, y: 8)))      // hole beside the bar
        #expect(!grok.contains(CGPoint(x: 8, y: 8)))       // hole, far side
        let oc = SVGPathParser.path(AgentKind.opencode.brandMark)
        #expect(oc.contains(CGPoint(x: 6.5, y: 12)))       // frame wall
        #expect(!oc.contains(CGPoint(x: 12, y: 8)))        // gap above the block
        #expect(oc.contains(CGPoint(x: 12, y: 14)))        // block
        #expect(!oc.contains(CGPoint(x: 8.5, y: 14)))      // gap beside the block
    }

    /// The shape scales its 24-box into whatever rect it's given, centred.
    @Test func fitsAndCentresInRect() {
        let shape = SVGPathShape("M0 0h24v24H0z")
        let box = shape.path(in: CGRect(x: 10, y: 10, width: 60, height: 40)).boundingRect
        #expect(abs(box.width - 40) < 0.01 && abs(box.height - 40) < 0.01)
        #expect(abs(box.midX - 40) < 0.01 && abs(box.midY - 30) < 0.01)
    }
}
