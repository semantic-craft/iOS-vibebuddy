import SwiftUI
import VibeBuddyKit

/// The ambient status buddy: an emoji inside an animated colored ring whose mood
/// follows the most urgent session state. Pinned above the dashboard list.
struct BuddyView: View {
    let groups: SessionGroups
    @State private var animate = false

    private var state: BuddyState { BuddyState.from(groups) }
    private var animating: Bool { state == .working || state == .needsResponse }
    private var bouncing: Bool { state == .needsResponse }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .stroke(ring.opacity(0.9), lineWidth: 3)
                    .frame(width: 46, height: 46)
                    .scaleEffect(animating ? (animate ? 1.07 : 0.93) : 1)
                    .opacity(state == .working ? (animate ? 1 : 0.55) : 1)
                Text(emoji)
                    .font(.system(size: 26))
                    .offset(y: bouncing ? (animate ? -3 : 2) : 0)
            }
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
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { animate = true }
        }
    }

    private var emoji: String {
        switch state {
        case .needsResponse: "🔔"
        case .working: "🤖"
        case .done: "✅"
        case .sleeping: "😴"
        }
    }
    private var ring: Color {
        switch state {
        case .needsResponse: .orange
        case .working: .blue
        case .done: .green
        case .sleeping: .gray
        }
    }
    private var title: String {
        switch state {
        case .needsResponse: "需要你回应"
        case .working: "工作中…"
        case .done: "全部完成"
        case .sleeping: "休息中"
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
