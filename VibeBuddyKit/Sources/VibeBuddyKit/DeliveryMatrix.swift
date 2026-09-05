import Foundation

/// How loudly one cue reaches you. Ordered from silent to loud so a context
/// can only ever *cap* a level (`min`), never raise it.
public enum DeliveryLevel: Int, Sendable, Comparable, CaseIterable {
    /// Not posted anywhere.
    case drop = 0
    /// Added to Notification Center without a banner or a sound.
    case list
    /// A banner, no sound.
    case banner
    /// A banner with the cue's sound.
    case bannerSound

    public static func < (lhs: DeliveryLevel, rhs: DeliveryLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var makesSound: Bool { self == .bannerSound }

    /// Whether this level is worth pulling you away from something else: a
    /// banner on the Mac, a push to the phone. `list` and `drop` are not.
    public var interrupts: Bool { self >= .banner }
}

/// The one table that says how a cue reaches you given the session's attention
/// level. Shared by the Mac's local notifications, the Mac's push to the phone,
/// and the phone's own local notifications, so all three agree.
///
/// | cue            | followed     | normal       | muted   |
/// |----------------|--------------|--------------|---------|
/// | needsApproval  | banner+sound | banner+sound | banner  |
/// | needsAnswer    | banner+sound | banner+sound | banner  |
/// | agentStuck     | banner+sound | banner       | list    |
/// | agentDone      | banner       | banner       | drop    |
/// | longWaitNudge  | banner       | list         | drop    |
///
/// Approvals and questions are the two cues someone is blocked on, so they
/// interrupt at every level: a muted session still shows a silent banner. A
/// completion banners for any session whose device has the category on; only
/// the nudge is list-only by default. Quiet mode is the `muted` column for
/// every session. `pairSuccess` is not a session cue and is always loud. The
/// device's category switch is applied before this table: off means dropped.
public enum DeliveryMatrix {
    public static func level(for sound: NotificationSound, attention: SessionAttention) -> DeliveryLevel {
        switch (sound, attention) {
        case (.needsApproval, .followed), (.needsApproval, .normal),
             (.needsAnswer, .followed), (.needsAnswer, .normal): return .bannerSound
        case (.needsApproval, .muted), (.needsAnswer, .muted): return .banner
        case (.agentStuck, .followed): return .bannerSound
        case (.agentStuck, .normal): return .banner
        case (.agentStuck, .muted): return .list
        case (.agentDone, .followed), (.agentDone, .normal), (.longWaitNudge, .followed): return .banner
        case (.longWaitNudge, .normal): return .list
        case (.agentDone, .muted), (.longWaitNudge, .muted): return .drop
        case (.pairSuccess, _): return .bannerSound
        }
    }
}
