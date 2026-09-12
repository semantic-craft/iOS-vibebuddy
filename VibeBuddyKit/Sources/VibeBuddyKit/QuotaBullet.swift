import SwiftUI

/// One quota window as Stephen Few's bullet graph: the spent bar over two
/// qualitative zones (amber from 80%, red from 95%), plus a tick where even
/// spending would have reached by now. A bar on a common baseline is read
/// faster than an angle, and five of them fit where one dial would — which is
/// why the sidebar can carry every provider at once.
///
/// The tick is the graph's comparative measure: bar past tick means the window
/// is burning faster than the clock. Sources without a reset time (Grok Bot)
/// pass `pacePercent: nil` and simply draw without it.
public struct QuotaBullet: View {
    public let usedPercent: Int
    public let pacePercent: Int?
    public var height: CGFloat

    public init(usedPercent: Int, pacePercent: Int? = nil, height: CGFloat = 12) {
        self.usedPercent = usedPercent
        self.pacePercent = pacePercent
        self.height = height
    }

    private var used: Int { max(0, min(100, usedPercent)) }

    public var body: some View {
        let tint = QuotaPresentation.severity(usedPercent: used).tint
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(CompanionPalette.bg2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline)
                    }
                // Few's qualitative ranges are neutral on purpose: colour is
                // reserved for the measure, so a pale band is never mistaken
                // for "this much is left".
                zone(from: 0.80, to: 0.95, in: width, opacity: 0.07)
                zone(from: 0.95, to: 1.00, in: width, opacity: 0.14)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: max(2, width * CGFloat(used) / 100))
                    .padding(.vertical, 3)
                if let pace = pacePercent {
                    Rectangle()
                        .fill(CompanionPalette.ink2)
                        .frame(width: 2)
                        .offset(x: width * CGFloat(max(0, min(100, pace))) / 100 - 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private func zone(from start: CGFloat, to end: CGFloat, in width: CGFloat, opacity: Double) -> some View {
        Rectangle()
            .fill(CompanionPalette.ink.opacity(opacity))
            .frame(width: width * (end - start))
            .offset(x: width * start)
    }

    private var label: String {
        guard let pace = pacePercent else { return String(localized: "\(used)% used") }
        return String(localized: "\(used)% used, \(pace)% of the window elapsed")
    }
}

#Preview {
    VStack(spacing: 14) {
        QuotaBullet(usedPercent: 32, pacePercent: 55)
        QuotaBullet(usedPercent: 73, pacePercent: 43)
        QuotaBullet(usedPercent: 88, pacePercent: 60)
        QuotaBullet(usedPercent: 97, pacePercent: 90)
        QuotaBullet(usedPercent: 12, pacePercent: nil)
    }
    .padding()
    .frame(width: 220)
    .background(CompanionPalette.bg)
}
