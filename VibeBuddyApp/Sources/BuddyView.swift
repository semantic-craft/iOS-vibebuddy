import SwiftUI
import VibeBuddyKit

/// The ambient status buddy, drawn with SwiftUI and SF Symbols so it has no
/// bundled third-party mascot artwork.
struct BuddyView: View {
    let groups: SessionGroups
    @State private var bounce = false

    private var state: BuddyState { BuddyState.from(groups) }

    var body: some View {
        HStack(spacing: 14) {
            BuddyMark(state: state, bounce: bounce)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .onAppear { bounce = true }
    }

    private var title: String {
        switch state {
        case .needsResponse: "需要回应"
        case .working: "干活中..."
        case .done: "全部搞定"
        case .sleeping: "打盹中..."
        }
    }

    private var subtitle: String {
        if groups.isEmpty { return "没有进行中的会话" }
        var parts: [String] = []
        if !groups.needsResponse.isEmpty { parts.append("\(groups.needsResponse.count) 待回应") }
        if !groups.working.isEmpty { parts.append("\(groups.working.count) 进行中") }
        if !groups.done.isEmpty { parts.append("\(groups.done.count) 已完成") }
        return parts.joined(separator: " · ")
    }
}

private struct BuddyMark: View {
    let state: BuddyState
    let bounce: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(Color(.secondarySystemBackground))
                .overlay(Circle().stroke(accent.opacity(0.28), lineWidth: 4))
                .overlay {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(accent)
                        .offset(y: state == .needsResponse && bounce ? -3 : 0)
                }

            Image(systemName: badge)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 23, height: 23)
                .background(accent, in: Circle())
                .offset(x: 4, y: -4)
        }
        .frame(width: 58, height: 58)
        .scaleEffect(state == .working && bounce ? 1.04 : 1)
        .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: bounce)
        .accessibilityHidden(true)
    }

    private var accent: Color {
        switch state {
        case .needsResponse: .orange
        case .working: .blue
        case .done: .green
        case .sleeping: .secondary
        }
    }

    private var badge: String {
        switch state {
        case .needsResponse: "bell.fill"
        case .working: "gearshape.fill"
        case .done: "checkmark"
        case .sleeping: "moon.fill"
        }
    }
}
