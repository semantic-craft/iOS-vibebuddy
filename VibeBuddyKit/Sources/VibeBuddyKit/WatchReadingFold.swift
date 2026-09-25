import Foundation

/// How much of a long text the wrist shows before it offers the rest (M-07).
///
/// The wrist never cuts a request or a result off for good: a text past the
/// limit shows a preview and a **Show more** that expands it in place, which
/// is Apple's rule for scrolling regions ("avoid truncating text … unless
/// people can open a separate view", HIG Typography). Below the limit the whole
/// text is shown and scrolled with the Crown, as Mail and Messages do.
///
/// The limit is counted in *width units*, not characters: a CJK character is
/// about twice as wide as a Latin one on the wrist, so it counts 2. That keeps
/// a Chinese and an English text folding at roughly the same height, and it
/// makes the rule a pure function a test can pin, where a measured line count
/// would depend on the watch size and the text size setting.
public struct WatchReadingFold: Equatable, Sendable {
    /// A waiting question or an approval's target. Generous: a decision needs
    /// the whole thing, so only an outlier (a pasted script, a 6 KB command
    /// the Mac relayed for the iPhone's sake) folds, roughly past two screens
    /// of a 40 mm watch. Always at least twice the longest target the wrist
    /// may decide on (`WatchApprovalEligibility.maxDetailLength`), so a
    /// command with an Approve button under it is never folded, even in CJK.
    public static let requestLimit = 600
    /// A result snippet on a task's detail: about four lines at 12 pt on
    /// 40 mm, so the summary and the agent's own words both fit on the first
    /// screen and each expands on its own.
    public static let resultLimit = 110
    /// Past this a question is set in the body size rather than the title
    /// size, so a long one does not push its answers several screens down.
    public static let longQuestion = 120

    public let full: String
    /// The text to show while folded; equal to `full` when nothing is hidden.
    public let preview: String

    public var isFolded: Bool { preview != full }

    public init(_ text: String, limit: Int) {
        full = text
        preview = Self.cut(text, limit: limit)
    }

    /// Width units of `text` on the wrist, per character (grapheme): 2 for an
    /// East Asian wide one, 1 for anything else. Per character, not per
    /// scalar, because that is what the approval gate counts
    /// (`maxDetailLength` is `String.count`): a decomposed Hangul path or a
    /// ZWJ emoji is one character on screen and must not weigh four.
    public static func width(_ text: String) -> Int {
        text.reduce(0) { $0 + units($1) }
    }

    private static func units(_ character: Character) -> Int {
        character.unicodeScalars.contains(where: isWide) ? 2 : 1
    }

    private static func cut(_ text: String, limit: Int) -> String {
        // A tenth of slack, so Show more never hides a word or two, and a
        // text with nothing to show but whitespace is never folded into "…".
        // (Written as a difference so `limit: .max` cannot overflow.)
        guard width(text) - limit > limit / 10,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let step = units(text[index])
            if used + step > limit { break }
            used += step
            end = text.index(after: index)
        }
        var head = text[..<end]
        // Prefer a word boundary in the last third, so English does not stop
        // mid-word; CJK and one long token (a path, a URL) keep the hard cut.
        if let space = head.lastIndex(where: \.isWhitespace),
           width(String(head[..<space])) >= limit * 2 / 3 {
            head = head[..<space]
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
