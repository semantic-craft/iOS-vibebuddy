import SwiftUI

struct NotchShape: Shape {
    var topRadius: CGFloat = 8
    var bottomRadius: CGFloat = 14
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
                       control: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
                       control: CGPoint(x: rect.minX + topRadius, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
                       control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
