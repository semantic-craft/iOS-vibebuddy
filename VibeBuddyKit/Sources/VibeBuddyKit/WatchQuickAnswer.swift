import Foundation

/// What a wrist may answer a question with without dictating, and the rule that
/// decides which of those it is offered.
///
/// A question on a 40mm screen is answered in one tap or not at all. Most of
/// them take the same handful of replies, so those are a fixed set here — not
/// editable, not per-project, not learned (spec, 2026-09-08). Dictation is the
/// way out of the set, never the only way in.
///
/// Two rules shape what is offered, and both are here rather than in a view so
/// the Watch cannot drift from what the iPhone will honour:
///
/// 1. **The agent's own options win.** When the question came with choices, the
///    general phrases are wrong answers to it — "Run the tests first" is not one
///    of "Tighten" or "Plain language" — so the options replace them entirely
///    and "Something else" leads to dictation.
/// 2. **A phrase is sent in the language it was read in.** The label is not a
///    caption over an English payload: it *is* the text the agent receives.
///    Anything else would make the confirmation page — the one screen whose
///    whole job is showing what will be sent — a lie.
public enum WatchAnswerPhrase: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    /// The common one, and deliberately first: most questions are a checkpoint.
    case goAhead
    case decline
    /// Answers the shape of question that offered choices the Watch cannot read
    /// in full, without needing to name one.
    case firstOption
    case testFirst
    /// Not an answer so much as a brake — it tells the agent to stop proposing
    /// and wait, which is what a person on the move usually means.
    case later

    public var id: String { rawValue }

    /// The text the agent receives, resolved in the bundle of whichever app is
    /// showing it — the same way `WatchStopBlock.message` is worded where it is
    /// read, so a Chinese Watch sends Chinese and an English one sends English.
    public var text: String {
        switch self {
        case .goAhead: return String(localized: "Yes, go ahead.")
        case .decline: return String(localized: "No, don't do that.")
        case .firstOption: return String(localized: "Use the first option.")
        case .testFirst: return String(localized: "Run the tests first.")
        case .later: return String(localized: "Hold off for now — I'll look at this later.")
        }
    }
}

/// One tappable answer: a fixed phrase, or a choice the agent itself offered.
public enum WatchQuickReply: Equatable, Sendable, Identifiable {
    case phrase(WatchAnswerPhrase)
    /// One of `WatchAlert.options`, which are labels: `QuestionOption.value`
    /// is not relayed to the wrist.
    ///
    /// So the label is both what is shown and what is sent, which is the
    /// property the confirmation page depends on. The phone sends `value`
    /// instead, and the two differ only for a question read from an older
    /// CLI's transcript — every live producer sets `value` to the label. When
    /// they do differ, the wrist sends the words the wearer actually read,
    /// which is the trade this page is built to make.
    case option(String)

    public var id: String {
        switch self {
        case .phrase(let phrase): return "phrase:\(phrase.rawValue)"
        case .option(let label): return "option:\(label)"
        }
    }

    /// Exactly what will be sent, and exactly what the confirmation page shows.
    public var text: String {
        switch self {
        case .phrase(let phrase): return phrase.text
        case .option(let label): return label
        }
    }
}

/// The quick answers offered for one alert, and where they came from.
///
/// `nil` from `resolve(for:)` is the third answer and the important one: this
/// alert takes no answer from the wrist at all, so nothing is drawn and the
/// card keeps saying where to go instead.
public struct WatchQuickAnswers: Equatable, Sendable {
    /// Which set is on screen. The view needs it for one word — the way out of
    /// the set is "Something else" among the agent's own choices and "Dictate"
    /// among general phrases — and a test needs it to prove the swap happened.
    public enum Source: String, Equatable, Sendable {
        case phrases
        case options
    }

    /// The most option buttons a wrist is asked to scroll past before the way
    /// out of the list. Beyond this the list stops being a list.
    public static let maxOptions = 6

    public var source: Source
    public var replies: [WatchQuickReply]
    /// How many of the agent's options did not fit. A choice that is silently
    /// absent reads as a choice that was never offered, so the wrist says the
    /// list was cut rather than presenting six of eight as the whole of it.
    public var omittedOptions: Int

    public init(source: Source, replies: [WatchQuickReply], omittedOptions: Int = 0) {
        self.source = source
        self.replies = replies
        self.omittedOptions = omittedOptions
    }

    /// What this alert may be answered with, or `nil` when it may not be
    /// answered from here.
    ///
    /// The gate is `WatchAlert.isAnswerable` — the same rule the iPhone re-runs
    /// on the tap — so a card that offers a phrase is a card whose answer will
    /// be forwarded, and a read-only wait never grows a button.
    public static func resolve(for alert: WatchAlert) -> WatchQuickAnswers? {
        guard alert.isAnswerable else { return nil }
        let offered = cleanedOptions(alert.options)
        if !offered.isEmpty {
            return WatchQuickAnswers(source: .options,
                                     replies: offered.map(WatchQuickReply.option),
                                     omittedOptions: max(0, readableOptions(alert.options).count
                                                            - offered.count))
        }
        // An alert whose options were all blank is a question with no readable
        // choices, which is the same situation as a question with none.
        return WatchQuickAnswers(source: .phrases,
                                 replies: WatchAnswerPhrase.allCases.map(WatchQuickReply.phrase))
    }

    /// Labels as they can actually be sent: trimmed, no blanks, no repeats, and
    /// bounded. An agent's option list is data, not a promise about length.
    private static func cleanedOptions(_ labels: [String]) -> [String] {
        Array(readableOptions(labels).prefix(maxOptions))
    }

    /// Every label that could be shown at all, before the bound is applied —
    /// the denominator for "and N more".
    private static func readableOptions(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        for label in labels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            kept.append(trimmed)
        }
        return kept
    }
}
