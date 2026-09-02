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
    var companionEnabled: Bool = true   // false → off-state header (opt-in gate)
    var buddyScopeCount: Int = 0         // live sessions scoped into the buddy (0 = all)
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
                    if !companionEnabled {
                        Label("Voice companion off", systemImage: "mic.slash")
                            .font(.headline).foregroundStyle(.secondary)
                    } else {
                        Text(listening ? "Listening…" : (speaking ? "Speaking…" : title(state))).font(.headline)
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    if companionEnabled {
                        Text(scopeLine).font(.caption2).foregroundStyle(.tertiary)
                    }
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

    private func title(_ state: BuddyState) -> LocalizedStringKey {
        switch state {
        case .approval: "Waiting for approval"
        case .question: "Waiting for your answer"
        case .longWait: "Been waiting a while…"
        case .working:  "Working…"
        case .stuck:    "Stuck"
        case .done:     "All done"
        case .idle:     "Idle"
        case .sleeping: "Napping…"
        }
    }

    /// "Buddy: all sessions" when nothing is scoped, else "Buddy: N selected".
    private var scopeLine: LocalizedStringKey {
        buddyScopeCount == 0 ? "Buddy: all sessions" : "Buddy: \(buddyScopeCount) selected"
    }

    private var subtitle: String {
        if groups.isEmpty { return String(localized: "No active sessions") }
        let sessions = groups.needsResponse + groups.working + groups.done
        let summary = TaskPresentationSummary(sessions: sessions)
        var parts: [String] = []
        for state in [TaskPresentationState.error, .requiresInput, .thinking, .completeUnread, .idle] {
            let count = summary.count(for: state)
            if count > 0 { parts.append("\(count) \(state.label.lowercased())") }
        }
        return parts.joined(separator: " · ")
    }
}
