import Foundation

/// Decides whether something the user just said should end the live voice call,
/// so they can close it hands-free instead of tapping the pet.
///
public enum VoiceCloseIntent {
    /// Narrow local control for completed transcripts or settled Live captions.
    /// Requires an entire, explicit call-ending command.
    /// The coordinator also waits for text to settle before acting.
    public static func isExplicitCallEnd(_ transcript: String) -> Bool {
        guard !transcript.contains(where: { "?？\"'“”‘’「」『』《》〈〉«»‹›＂＇".contains($0) }) else { return false }
        let clean = transcript.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0)
        }.map(String.init).joined()
        let patterns = [
            "^(好的|好|那)?(请|麻烦)?(立即|现在|帮我)?(挂断|结束|关闭)(这次|本次|当前)?(语音)?(通话|对话)(吧|再见)?$",
            "^(please)?(hangup(this|the)?call|end(this|the)(voice)?call|disconnect(this|the)call)(now|please)?$",
        ]
        return patterns.contains { clean.range(of: $0, options: .regularExpression) != nil }
    }

}
