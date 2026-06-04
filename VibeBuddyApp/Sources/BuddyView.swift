import SwiftUI
import Lottie
import VibeBuddyKit

/// The ambient status buddy — a Lottie cat animation, with state cues overlaid
/// (a "批准?" sign when it needs you, a "z" when idle). Pinned above the list.
/// Animations live in Resources/Buddy/*.json; falls back to an SF Symbol cat.
struct BuddyView: View {
    let groups: SessionGroups
    @State private var bounce = false

    /// Which bundled animation to play. (One cat for now; per-state later.)
    private let animationName = "cat_popof"
    private var state: BuddyState { BuddyState.from(groups) }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                LottieCat(name: animationName)
                    .frame(width: 60, height: 60)
                    .offset(y: state == .needsResponse && bounce ? -4 : 0)
                if state == .needsResponse { sign }
                if state == .sleeping { Text("z").font(.headline.weight(.heavy))
                    .foregroundStyle(.secondary).offset(x: 26, y: -22) }
                if state == .done { Text("✨").offset(x: 24, y: -22) }
            }
            .frame(width: 72, height: 60)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: bounce)
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

    private var sign: some View {
        VStack(spacing: 0) {
            Text("批准?")
                .font(.caption2.bold()).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.orange, in: .rect(cornerRadius: 5))
            Rectangle().fill(.brown).frame(width: 2, height: 8)
        }
        .offset(x: 26, y: -20)
    }

    private var title: String {
        switch state {
        case .needsResponse: "喵!要你批准"
        case .working: "干活中…"
        case .done: "全部搞定 ✨"
        case .sleeping: "打盹中…"
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

/// Plays a bundled Lottie animation, looping. Falls back to an SF Symbol cat
/// if the named .json isn't present.
private struct LottieCat: View {
    let name: String
    var body: some View {
        if Bundle.main.url(forResource: name, withExtension: "json") != nil {
            LottieView(animation: .named(name))
                .looping()
        } else {
            Image(systemName: "cat.fill")
                .resizable().scaledToFit()
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }
}
