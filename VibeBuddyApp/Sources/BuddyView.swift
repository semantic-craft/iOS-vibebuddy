import SwiftUI
import VibeBuddyKit

/// The ambient status buddy, drawn with SwiftUI and SF Symbols so it has no
/// bundled third-party mascot artwork. Its mood mirrors the sound pack so the
/// face you see matches the cue you hear.
struct BuddyView: View {
    let groups: SessionGroups
    var pulse: Int = 0          // bumped when a cue fires → the buddy reacts
    var speaking: Bool = false  // companion is talking
    var listening: Bool = false // companion is listening
    var onTap: (() -> Void)?    // tap the pet to talk
    @State private var react = false

    var body: some View {
        // A slow clock so a long wait can turn the buddy impatient over time.
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let state = BuddyState.from(groups, now: ctx.date)
            HStack(spacing: 14) {
                PetFace(state: state, speaking: speaking, listening: listening)
                    .scaleEffect(react ? 1.08 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.4), value: react)
                    .onTapGesture { onTap?() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(listening ? "在听…" : (speaking ? "说话中…" : title(state))).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .animation(.smooth, value: state)
            .onChange(of: pulse) { _, _ in
                react = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { react = false }
            }
        }
    }

    private func title(_ state: BuddyState) -> String {
        switch state {
        case .approval: "等你批准"
        case .question: "在等你回答"
        case .longWait: "等好久了…"
        case .working:  "干活中..."
        case .stuck:    "卡住了"
        case .done:     "全部搞定"
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

/// Maps a shared `BuddyAccent` to a concrete color (kept identical on Mac).
func buddyColor(_ accent: BuddyAccent) -> Color {
    switch accent {
    case .alert:     .orange
    case .curious:   .blue
    case .impatient: .pink
    case .busy:      .blue
    case .worry:     .red
    case .good:      .green
    case .calm:      .secondary
    }
}
