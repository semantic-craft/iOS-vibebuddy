import SwiftUI
import VibeBuddyKit

/// The iPhone header: the cat and its speech bubble. The cat says one line
/// about the whole snapshot (Companion, round 5); the voice status takes the
/// line over while the companion is listening or speaking.
struct BuddyView: View {
    let groups: SessionGroups
    var pulse: Int = 0          // bumped when a cue fires → the buddy reacts
    var voice: BuddyCatMotion.Voice = .none   // the companion's voice phase
    var companionEnabled: Bool = true   // false → off-state header (opt-in gate)
    var buddyScopeCount: Int = 0         // live sessions scoped into the buddy (0 = all)
    var onTap: (() -> Void)?    // tap the pet to talk
    @State private var react = false
    @State private var greet = 0

    private var summary: TaskPresentationSummary {
        TaskPresentationSummary(sessions: groups.needsResponse + groups.working + groups.done)
    }

    var body: some View {
        // A slow clock so a long wait can turn the buddy impatient over time.
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let state = BuddyState.from(groups, now: ctx.date)
            HStack(spacing: 14) {
                PetFace(state: state, voice: voice, greet: greet)
                    .scaleEffect(react ? 1.08 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.4), value: react)
                    .onTapGesture { greet += 1; onTap?() }
                SpeechBubble {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline)
                            .font(CompanionType.font(15, .black))
                            .foregroundStyle(CompanionPalette.ink)
                            .lineLimit(2)
                        Text(subline)
                            .font(CompanionType.font(11, .bold))
                            .foregroundStyle(CompanionPalette.ink2)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth, value: state)
            .onChange(of: pulse) { _, _ in
                react = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { react = false }
            }
        }
    }

    private var headline: String {
        switch voice {
        case .listening: return String(localized: "Listening…")
        case .speaking: return String(localized: "Speaking…")
        case .thinking: return String(localized: "Thinking…")
        case .none: break
        }
        if groups.isEmpty { return String(localized: "Napping — no sessions") }
        return CompanionCopy.moodLine(summary)
    }

    private var subline: String {
        var parts: [String] = []
        let rest = CompanionCopy.restLine(summary)
        if !rest.isEmpty { parts.append(rest) }
        if !companionEnabled {
            parts.append(String(localized: "Voice companion off"))
        } else if buddyScopeCount > 0 {
            parts.append(String(localized: "Buddy: \(buddyScopeCount) selected"))
        } else {
            parts.append(String(localized: "Tap me to talk"))
        }
        return parts.joined(separator: " · ")
    }
}
