import SwiftUI

/// A thin strip under the buddy showing the voice conversation state: what you
/// said, what it replied, or an error / hint.
struct VoiceStrip: View {
    @ObservedObject var voice: VoiceChat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(voice.errorText != nil ? .red : .accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                if let err = voice.errorText {
                    Text(err).font(.caption).foregroundStyle(.red)
                } else {
                    if !voice.lastUserText.isEmpty {
                        Text(voice.lastUserText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !voice.lastReply.isEmpty {
                        Text(voice.lastReply).font(.caption.weight(.medium)).lineLimit(2)
                    } else if voice.phase == .listening {
                        Text("在听…轻点宠物结束").font(.caption).foregroundStyle(.secondary)
                    } else if voice.phase == .thinking {
                        Text("思考中…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var icon: String {
        if voice.errorText != nil { return "exclamationmark.circle" }
        switch voice.phase {
        case .listening: return "mic.fill"
        case .thinking:  return "ellipsis"
        case .speaking:  return "waveform"
        case .idle:      return "mic"
        }
    }
}
