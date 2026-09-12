import Foundation

/// The wrist's vocabulary: four things the Watch can say without words, the
/// rhythm it says each of them in, and the rule that decides when it says
/// nothing at all.
///
/// This is pure. The Watch owns the actual tap (`WKInterfaceDevice.play`); the
/// Kit owns which taps, in what order, and whether they happen — so the rules
/// can be tested without a device, exactly as `SoundPolicy` is.

// MARK: - Beats

/// One tap of a wrist rhythm, named for the built-in `WKHapticType` the Watch
/// plays it with. There is no custom haptic engine here: watchOS only offers
/// these canned taps, so a rhythm is made of *counts and spacing*, not of
/// waveform design.
public enum WristHapticBeat: String, Codable, Sendable, Equatable, CaseIterable {
    /// The shortest tap the device has (`WKHapticType.click`).
    case short
    /// A heavier, more drawn-out tap (`WKHapticType.directionUp`).
    case long

    /// How long to wait after starting this beat before starting the next one.
    ///
    /// Without a gap the taps merge into one buzz and the count — which is what
    /// carries the meaning — is lost. Long beats sit further apart so two longs
    /// cannot be mistaken for two shorts.
    public var spacing: TimeInterval {
        switch self {
        case .short: return 0.25
        case .long:  return 0.55
        }
    }
}

// MARK: - Events

/// The four things worth feeling on a wrist. Deliberately coarser than
/// `NotificationCategory`: a permission and a question both mean *you are being
/// waited on*, and a wrist cannot carry that distinction as a rhythm anyone
/// would learn.
public enum WristEvent: String, Codable, Sendable, Equatable, CaseIterable {
    /// A session is blocked on you (`needsApproval` or `needsAnswer`).
    case needsYou
    /// A session finished (`agentDone`).
    case done
    /// A session ended badly (`agentStuck`).
    case error
    /// An account allowance is nearly spent (`quota`).
    case quotaLow
}

// MARK: - Quiet

/// The phone's Quiet settings as *settings*, not as a verdict.
///
/// A relayed "it is quiet right now" would be describing the moment the payload
/// was written; the Watch decides against its own clock instead, the same way
/// it derives freshness and `WatchConnection` for itself.
public struct WatchQuietSettings: Codable, Sendable, Equatable {
    public var manual: Bool
    public var hours: QuietHours

    public init(manual: Bool = false, hours: QuietHours = QuietHours()) {
        self.manual = manual
        self.hours = hours
    }

    public func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        manual || hours.isQuiet(at: date, calendar: calendar)
    }
}

// MARK: - Vocabulary

public enum WatchHaptics {
    /// At or below this much of an allowance left, the wrist calls it nearly
    /// spent. Same boundary the Watch's own quota strip already colours as low,
    /// and the complement of the Mac's default 90%-used alert threshold.
    public static let lowQuotaPercent = 10

    /// The wrist event a notification category belongs to, if it is one of the
    /// four. The long-wait nudge and the pairing chime are not: a nudge repeats
    /// something the wrist has already said, and pairing is chrome.
    public static func event(for category: NotificationCategory) -> WristEvent? {
        switch category {
        case .needsApproval, .needsAnswer: return .needsYou
        case .agentStuck:                  return .error
        case .agentDone:                   return .done
        case .quota:                       return .quotaLow
        case .longWaitNudge, .pairSuccess: return nil
        }
    }

    /// The rhythm for an event, before any muting.
    ///
    /// Five heavier taps for "you are being waited on" — the only one you must
    /// act on. The longer sequence stays noticeable on a real wrist. One short tap for a result. Two long taps
    /// for a failure, heavier and slower so it does not read as good news. A
    /// short then a long for an allowance running out, which belongs to neither
    /// family.
    public static func beats(for event: WristEvent) -> [WristHapticBeat] {
        switch event {
        case .needsYou: return [.long, .long, .long, .long, .long]
        case .done:     return [.short]
        case .error:    return [.long, .long]
        case .quotaLow: return [.short, .long]
        }
    }

    /// What this device should actually play for `category` — an empty sequence
    /// when it should stay still.
    ///
    /// Two mute rules, both from the notification model this mirrors:
    ///   - a category the person switched off is never said at all;
    ///   - Quiet silences the session cues, and *not* quota, which is
    ///     independent of Quiet mode and Quiet hours and answers only to its own
    ///     switch (CONTEXT: NotificationCategory / SessionAttention).
    public static func rhythm(for category: NotificationCategory,
                              categories: NotificationCategoryPrefs,
                              quiet: Bool) -> [WristHapticBeat] {
        guard let event = event(for: category), categories.isEnabled(category) else { return [] }
        if quiet, category != .quota { return [] }
        return beats(for: event)
    }

    /// Which cue wins when one snapshot brings several.
    ///
    /// Playing two rhythms back to back would be unreadable, so a snapshot says
    /// one thing. The order is `DeliveryMatrix`'s: approvals and questions
    /// interrupt at every attention level, a failure is quieter than that, a
    /// completion quieter still, and quota is not a session cue at all.
    static func rank(_ category: NotificationCategory) -> Int {
        switch category {
        case .needsApproval, .needsAnswer: return 0
        case .agentStuck:                  return 1
        case .agentDone:                   return 2
        case .quota:                       return 3
        case .longWaitNudge, .pairSuccess: return 4
        }
    }

    /// The one thing to say for a snapshot that brought several cues: the most
    /// urgent one this device is actually allowed to feel.
    ///
    /// Muting is applied *while* choosing, not after. A cue the person switched
    /// off does not get to spend the snapshot's single turn to speak and leave
    /// the wrist silent — the next one down takes it. Otherwise a completion
    /// silenced by Quiet would swallow the allowance warning that arrived with
    /// it, and quota, which answers only to its own switch, would be muted by a
    /// setting that is not supposed to reach it.
    public static func cue(forAnyOf cues: [NotificationCategory],
                           categories: NotificationCategoryPrefs,
                           quiet: Bool) -> WristHapticCue? {
        for category in cues.sorted(by: { rank($0) < rank($1) }) {
            let beats = rhythm(for: category, categories: categories, quiet: quiet)
            if !beats.isEmpty { return WristHapticCue(category: category, beats: beats) }
        }
        return nil
    }
}

/// One thing the wrist is about to say, and how.
public struct WristHapticCue: Equatable, Sendable {
    public let category: NotificationCategory
    public let beats: [WristHapticBeat]

    public init(category: NotificationCategory, beats: [WristHapticBeat]) {
        self.category = category
        self.beats = beats
    }
}

// MARK: - Transitions

/// Which cue, if any, a newly arrived Watch state has earned.
///
/// The wrist buzzes on *boundaries*, never on refreshes: a session entering
/// `requiresInput`, `error` or `completeUnread`, or an allowance crossing into
/// nearly-spent. Holding a session in the same state across ten snapshots is
/// silent, and so is the backlog that is already there when the app launches —
/// the same rule `SoundPolicy` applies when it first connects.
///
/// Pure and diffing-only: it decides *what* to say, never plays anything, and
/// carries no clock of its own.
public struct WatchHapticTransitions: Sendable, Equatable {
    /// The Mac + pairing this memory describes. A different one is a new world,
    /// not a set of transitions.
    private var source: String?
    /// Session id → the cue it is currently in. Absent means "in none of them".
    private var known: [String: NotificationCategory] = [:]
    /// Providers whose shown allowance currently reads as nearly spent.
    private var lowQuota: Set<AccountUsageProvider> = []
    private var seenFirstState = false

    public init() {}

    /// Record `state` and return every cue it earned, most urgent first.
    ///
    /// The caller says only one of them (`WatchHaptics.cue(forAnyOf:…)`), but it
    /// gets the whole list because muting is decided there: a switched-off cue
    /// must not use up the snapshot's single turn to speak.
    ///
    /// Always call this for every state that arrives, foreground or not:
    /// recording is what stops a transition the wrist slept through from being
    /// replayed as news when the app comes forward.
    public mutating func advance(to state: WatchDashboardState, now: Date) -> [NotificationCategory] {
        let identity = Self.identity(of: state)
        let current = Self.cues(in: state)
        // A different Mac or pairing is a new world: nothing carries over into it.
        let sameWorld = seenFirstState && source == identity
        let previous = sameWorld ? known : [:]
        let previousLow = sameWorld ? lowQuota : []
        let low = Self.lowProviders(in: state, now: now, carrying: previousLow)

        let wasStarted = seenFirstState
        source = identity
        known = current
        lowQuota = low
        seenFirstState = true

        // Nothing to compare against: the first state, or the first from a
        // different Mac / pairing. Everything in it is history, not news.
        guard wasStarted, sameWorld else { return [] }

        var fired: Set<NotificationCategory> = []
        for (sessionID, category) in current where previous[sessionID] != category {
            fired.insert(category)
        }
        if !low.subtracting(previousLow).isEmpty {
            fired.insert(.quota)
        }
        return fired.sorted {
            WatchHaptics.rank($0) == WatchHaptics.rank($1)
                ? $0.rawValue < $1.rawValue
                : WatchHaptics.rank($0) < WatchHaptics.rank($1)
        }
    }

    private static func identity(of state: WatchDashboardState) -> String {
        "\(state.sourceID ?? "-")|\(state.pairingEpoch ?? "-")"
    }

    /// Every session the wrist can name, and the cue it is currently in.
    ///
    /// Two sources, because the Watch's state carries the three presentation
    /// states in two different places: `alerts` holds every waiting session
    /// (and its wait kind, which decides approval from question), while
    /// `followedTasks` and `results` carry `error` and `completeUnread`.
    /// A waiting session appears in both; the alert wins, matching
    /// `WatchFollowedTask`'s own "explicit input wins over error" rule.
    private static func cues(in state: WatchDashboardState) -> [String: NotificationCategory] {
        var cues: [String: NotificationCategory] = [:]
        for task in state.followedTasks + (state.results ?? []) {
            switch task.presentation {
            case .error:          cues[task.sessionID] = .agentStuck
            case .completeUnread: cues[task.sessionID] = .agentDone
            case .requiresInput:  cues[task.sessionID] = task.waitKind == .permission ? .needsApproval : .needsAnswer
            case .thinking, .idle, .unassigned: continue
            }
        }
        for alert in state.alerts {
            cues[alert.sessionId] = alert.waitKind == .permission ? .needsApproval : .needsAnswer
        }
        return cues
    }

    /// Providers whose shown allowance reads as nearly spent right now.
    ///
    /// Only a *live reading above the line* clears a verdict. Anything else —
    /// stale, cached, awaiting a reset, or the provider missing from the state
    /// altogether — leaves the previous verdict standing. Absence is common and
    /// means nothing: the Mac's snapshot carries `providerQuota` optionally, so
    /// one snapshot without it relays an empty quota list under the *same* Mac
    /// and pairing. Clearing on absence would let the next reading of the same
    /// exhausted window buzz all over again. Only a new Mac or a re-pairing
    /// resets the verdicts, and that is handled by the caller.
    private static func lowProviders(in state: WatchDashboardState, now: Date,
                                     carrying previous: Set<AccountUsageProvider>)
        -> Set<AccountUsageProvider> {
        var low = previous
        for quota in state.quotas {
            let reading = quota.displayWindow(preferring: .weekly)
            guard reading.status(now: now) == .live,
                  let remaining = reading.currentRemainingPercent(now: now) else { continue }
            if remaining <= WatchHaptics.lowQuotaPercent {
                low.insert(quota.provider)
            } else {
                low.remove(quota.provider)
            }
        }
        return low
    }
}

// MARK: - What the Watch mutes against

public extension WatchDashboardState {
    /// The notification switches this wrist obeys.
    ///
    /// The Watch mirrors what the phone shows, so it mirrors the phone's
    /// switches too; a relay from a build that predates them reads as the phone
    /// default (approvals, questions, failures and completions on, quota off).
    var effectiveCategories: NotificationCategoryPrefs {
        categories ?? .default
    }

    /// Whether Quiet is in force at `now`, decided here against the Watch's own
    /// clock from the relayed settings.
    func isQuiet(at now: Date) -> Bool {
        quiet?.isQuiet(at: now) ?? false
    }
}
