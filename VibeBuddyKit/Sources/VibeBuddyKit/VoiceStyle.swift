import Foundation

/// A persona for read-aloud, layered on top of whichever voice is chosen.
///
/// No vendor takes a style *flag*: Volcengine, Alibaba and Google all control
/// delivery with a natural-language instruction, so a tier is a sentence we
/// send, not an enum they recognise. What differs between them is only the
/// grammatical form their docs use, so this file owns every word we say and
/// each vendor's Kit file picks a form and a place to put it. That split is
/// why adding a fourth vendor never edits this file.
///
/// `.standard` is the pre-existing behaviour, kept as a real option rather
/// than a hidden one: a persona is taste, and someone who wants a summary read
/// plainly must be able to say so.
public enum VoiceStyle: String, Sendable, CaseIterable, Equatable {
    case standard
    case girlNextDoor
    case fieryGirl

    /// English source text; the app's string tables translate it.
    public var display: String {
        switch self {
        case .standard: NSLocalizedString("Standard", comment: "Read-aloud voice style")
        case .girlNextDoor: NSLocalizedString("Girl next door", comment: "Read-aloud voice style")
        case .fieryGirl: NSLocalizedString("Fiery girl", comment: "Read-aloud voice style")
        }
    }

    /// The persona to send, in the language being spoken — the instruction has
    /// to match the summary's language, or the vendor hears a language switch
    /// rather than a note about delivery. `nil` for `.standard`, and callers
    /// must then send the request exactly as they did before styles existed.
    public func persona(_ language: VoiceLanguage) -> VoicePersona? {
        switch (self, language) {
        case (.standard, _):
            return nil
        case (.girlNextDoor, .chinese):
            return .init("像邻家小妹一样亲切甜美、语速自然、尾音轻柔，带点腼腆的笑意", language)
        case (.girlNextDoor, .english):
            return .init("like the girl next door — warm, sweet and unhurried, with a shy smile in the voice", language)
        case (.fieryGirl, .chinese):
            return .init("像火辣少女一样热情张扬、明快有力，尾音带点撩人的上扬", language)
        case (.fieryGirl, .english):
            return .init("like a fiery young woman — bold and playful, brisk and punchy, with a teasing lift at the end", language)
        }
    }

    /// A stored value this build cannot parse is `.standard`, for the same
    /// reason an unknown provider is no pin: inventing a persona is worse than
    /// reading plainly.
    public init(stored: String?) {
        self = VoiceStyle(rawValue: (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? .standard
    }
}

/// One persona, ready to be said three ways. Each vendor documents its
/// instruction channel with a different grammatical form, and matching it
/// matters — the model was tuned on those examples — so the forms live here
/// together instead of being re-derived in three Kit files.
public struct VoicePersona: Sendable, Equatable {
    /// The adverbial clause every form is built from.
    public let clause: String
    let language: VoiceLanguage

    init(_ clause: String, _ language: VoiceLanguage) {
        self.clause = clause
        self.language = language
    }

    /// A conversational request, for a vendor whose examples ask the voice for
    /// something ("你可以用特别特别痛心的语气说话吗?").
    public var request: String {
        switch language {
        case .chinese: "你能\(clause)地说话吗？"
        case .english: "Could you speak \(clause)?"
        }
    }

    /// A directive, for a vendor whose examples tell the voice what to do
    /// ("请用河南话表达。").
    public var directive: String {
        switch language {
        case .chinese: "请\(clause)地表达。"
        case .english: "Please speak \(clause)."
        }
    }

    /// A lead-in for a vendor with no instruction field, where the only way in
    /// is the prompt itself ("Say in a spooky whisper: …"). Ends at the colon;
    /// the caller joins it to the text.
    public var leadIn: String {
        switch language {
        case .chinese: "请\(clause)地念出下面这段话："
        case .english: "Say the following \(clause):"
        }
    }
}
