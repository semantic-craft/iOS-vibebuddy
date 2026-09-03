#if canImport(SwiftUI)
import SwiftUI

public extension Color {
    init(taskStatus token: TaskStatusColorToken) {
        self.init(
            .sRGB,
            red: Double(token.red) / 255,
            green: Double(token.green) / 255,
            blue: Double(token.blue) / 255,
            opacity: 1
        )
    }
}

/// Shared status mark. Selection pulses in the task's existing state color; with
/// Reduce Motion it becomes a static outer ring. Differentiate Without Color
/// swaps the dot for a state-specific symbol.
public struct TaskStatusIndicator: View {
    public let state: TaskPresentationState
    public let isSelected: Bool
    public let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    public init(_ state: TaskPresentationState, isSelected: Bool = false, size: CGFloat = 10) {
        self.state = state
        self.isSelected = isSelected
        self.size = size
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isSelected || state == .unassigned)) { context in
            let phase = (sin(context.date.timeIntervalSinceReferenceDate * .pi * 1.25) + 1) / 2
            let animatedScale = 1.2 + phase * 0.45
            let ringScale = reduceMotion ? 1.35 : animatedScale
            let ringOpacity = reduceMotion ? 0.9 : 0.25 + (1 - phase) * 0.55

            ZStack {
                if isSelected, state != .unassigned {
                    if state == .idle, colorScheme == .light {
                        Circle()
                            .stroke(borderColor, lineWidth: contrast == .increased ? 4 : 3)
                            .scaleEffect(ringScale)
                            .opacity(ringOpacity)
                    }
                    Circle()
                        .stroke(statusColor, lineWidth: contrast == .increased ? 2 : 1.5)
                        .scaleEffect(ringScale)
                        .opacity(ringOpacity)
                }
                mark
            }
        }
        .frame(width: differentiateWithoutColor ? max(size, 12) : size,
               height: differentiateWithoutColor ? max(size, 12) : size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isSelected ? "Selected, \(state.label)" : state.label)
    }

    @ViewBuilder
    private var mark: some View {
        if state == .unassigned {
            Color.clear
        } else if differentiateWithoutColor {
            if state == .idle {
                ZStack {
                    Image(systemName: "circle.fill").foregroundStyle(statusColor)
                    Image(systemName: "circle").foregroundStyle(borderColor)
                }
                .font(.system(size: max(size, 12) * 0.72, weight: .bold))
            } else {
                Image(systemName: state.symbolName)
                    .font(.system(size: max(size, 12) * 0.72, weight: .bold))
                    .foregroundStyle(statusColor)
            }
        } else {
            Circle()
                .fill(statusColor)
                .overlay {
                    Circle().strokeBorder(borderColor, lineWidth: borderWidth)
                }
        }
    }

    private var statusColor: Color { Color(taskStatus: state.colorToken) }

    private var borderColor: Color {
        if state == .idle { return colorScheme == .light ? .black.opacity(0.55) : .white.opacity(0.85) }
        return contrast == .increased ? .primary.opacity(0.75) : .clear
    }

    private var borderWidth: CGFloat {
        if state == .idle { return contrast == .increased ? 2 : 1 }
        return contrast == .increased ? 1 : 0
    }
}
#endif
