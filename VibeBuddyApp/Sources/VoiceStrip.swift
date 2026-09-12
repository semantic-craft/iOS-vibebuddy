import SwiftUI
import VibeBuddyKit

/// A thin strip over the composer showing the voice conversation state: what you
/// said, what it replied, or an error / hint — plus which provider is live.
struct VoiceStrip: View {
    @ObservedObject var voice: VoiceChat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            // The cat is the conversation's avatar (ADR-0017 §2): it appears
            // here while a call is live and nowhere else on the phone.
            if voice.errorText == nil, voice.phase != .idle {
                BuddyCatFace(mood: .calm, speaking: voice.phase == .speaking,
                             listening: voice.phase == .listening,
                             showsBody: false, onDark: colorScheme == .dark)
                    .frame(width: 22, height: BuddyCat.height(forWidth: 22, showsBody: false))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(voice.errorText != nil ? CompanionPalette.status(.error) : CompanionPalette.accent)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let err = voice.errorText {
                    Text(err).font(CompanionType.font(12)).foregroundStyle(CompanionPalette.status(.error))
                } else if voice.phase == .recovering {
                    Text("Recovering audio… tap the mic to end").font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                } else {
                    if !voice.lastUserText.isEmpty {
                        Text(voice.lastUserText).font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink3).lineLimit(1)
                    }
                    if !voice.lastReply.isEmpty {
                        Text(voice.lastReply).font(CompanionType.font(12, .medium)).foregroundStyle(CompanionPalette.ink).lineLimit(2)
                    } else if voice.phase == .listening {
                        Text("Listening… tap the mic to end").font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                    } else if voice.phase == .connecting {
                        Text("Connecting… tap the mic to cancel").font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                    } else if voice.phase == .thinking {
                        Text("Thinking…").font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                    }
                }
            }
            Spacer(minLength: 0)
            if let provider = voice.activeProvider {
                Text(provider.display)
                    .font(CompanionType.font(10, .medium))
                    .foregroundStyle(CompanionPalette.ink2)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(CompanionPalette.bg2, in: Capsule())
            }
        }
        .padding(.horizontal, PhoneMetrics.gutter).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.bg3)
        .overlay(alignment: .top) { PhoneDivider() }
        .overlay(alignment: .bottom) { PhoneDivider() }
    }

    private var icon: String {
        if voice.errorText != nil { return "exclamationmark.circle" }
        switch voice.phase {
        case .listening: return "mic.fill"
        case .connecting, .recovering, .thinking:  return "ellipsis"
        case .speaking:  return "waveform"
        case .idle:      return "mic"
        }
    }
}
