import Foundation

/// Decides whether something the user just said should end the live voice call,
/// so they can close it hands-free instead of tapping the pet.
///
/// Two tiers, tuned to avoid false triggers:
/// - **Farewells** (再见 / 拜拜 / bye / goodbye) close the call if they appear
///   anywhere — these are almost never said except to end a conversation.
/// - **Close commands** (关闭 / 结束 / 停 / stop / …) close only when they are the
///   *whole* utterance, so "帮我关闭那个文件" or "stop editing main.swift" don't.
public enum VoiceCloseIntent {
    /// Narrow local control for completed transcripts or settled Live captions. Unlike the legacy
    /// farewell matcher, this requires an entire, explicit call-ending command.
    /// The coordinator also waits for text to settle before acting.
    public static func isExplicitCallEnd(_ transcript: String) -> Bool {
        guard !transcript.contains(where: { "?？\"'“”‘’".contains($0) }) else { return false }
        let clean = transcript.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0)
        }.map(String.init).joined()
        let patterns = [
            "^(好的|好|那)?(请|麻烦)?(立即|现在|帮我)?(挂断|结束|关闭)(这次|本次|当前)?(语音)?(通话|对话)(吧|再见)?$",
            "^(please)?(hangup(this|the)?call|end(this|the)(voice)?call|disconnect(this|the)call)(now|please)?$",
        ]
        return patterns.contains { clean.range(of: $0, options: .regularExpression) != nil }
    }

    private static let farewells = ["再见", "拜拜", "goodbye", "bye"]
    private static let commands = [
        "关闭", "结束", "结束对话", "结束吧", "停", "停下", "停止", "退出",
        "stop", "quit", "exit", "done",
    ]

    public static func shouldClose(_ transcript: String) -> Bool {
        let clean = transcript.lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(.punctuationCharacters).union(.symbols))
        guard !clean.isEmpty else { return false }
        let compact = clean.replacingOccurrences(of: " ", with: "")

        if farewells.contains(where: { compact.contains($0) }) { return true }
        if commands.contains(compact) { return true }
        return false
    }
}
