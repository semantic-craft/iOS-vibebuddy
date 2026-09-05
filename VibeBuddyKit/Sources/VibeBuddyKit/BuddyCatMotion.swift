import Foundation

/// How the cat is displaced for one frame, in the 52 × 60 unit space. All zero
/// (and `breath == 1`) draws the plain pose, so a static surface never needs it.
public struct BuddyCatPose: Sendable, Equatable {
    /// Vertical offset (negative = up): jumps and the speaking bob.
    public var bob: CGFloat = 0
    /// Horizontal offset: the working sway and the stuck shake.
    public var dx: CGFloat = 0
    /// Head tilt in degrees about the neck (26, 44). Positive tilts the head to the viewer's right.
    public var tilt: CGFloat = 0
    /// Ear rotation in degrees about each ear root; positive swings the ear outward.
    public var earL: CGFloat = 0
    public var earR: CGFloat = 0
    /// Where the eyes look, in unit points.
    public var eyeDx: CGFloat = 0
    public var eyeDy: CGFloat = 0
    /// Vertical scale about the feet: the breathing.
    public var breath: CGFloat = 1
    /// 0…1 size of the attached sweat drop by the right ear.
    public var sweat: CGFloat = 0
    /// Scale of the listening ring about its centre.
    public var ring: CGFloat = 1
    /// Opacity of the two sleeping z's.
    public var zA: CGFloat = 1
    public var zB: CGFloat = 1

    public init() {}

    public static let still = BuddyCatPose()

    /// Under 28 pt only the whole-sprite jump survives; sway, tilt, ear and eye
    /// motion are sub-pixel there and just read as shimmer.
    public func reduced(forWidth width: CGFloat) -> BuddyCatPose {
        guard width < BuddyCat.mouthThreshold else { return self }
        var p = BuddyCatPose()
        p.bob = bob
        p.sweat = sweat
        return p
    }
}

/// The pet's clock, as a pure function of time so every platform animates the
/// same way and it can be tested without a view. The rules follow OpenAI
/// Codex Pets: a state change is a short reaction (2–3 s) that settles into the
/// state's still pose plus slow breathing; idle is slow, uneven micro-motion; a
/// reaction expires; Reduce Motion is a still frame (the mouth still switches
/// shape while speaking). Voice phases layer on top of the state.
public enum BuddyCatMotion {
    public enum Voice: Sendable, Equatable { case none, listening, thinking, speaking }

    public struct Input: Sendable, Equatable {
        public var mood: BuddyCat.Mood
        /// When `mood` last changed; the reaction plays from here.
        public var moodChangedAt: Date
        public var voice: Voice = .none
        /// When the companion last stopped speaking; the cat closes its eyes happily for a moment.
        public var speakingEndedAt: Date? = nil
        /// When the pet was tapped or its panel opened; a short wave overrides the state motion.
        public var greetedAt: Date? = nil

        public init(mood: BuddyCat.Mood, moodChangedAt: Date, voice: Voice = .none,
                    speakingEndedAt: Date? = nil, greetedAt: Date? = nil) {
            self.mood = mood
            self.moodChangedAt = moodChangedAt
            self.voice = voice
            self.speakingEndedAt = speakingEndedAt
            self.greetedAt = greetedAt
        }
    }

    /// What `BuddyCatFace` should draw this frame.
    public struct Frame: Sendable, Equatable {
        public var mood: BuddyCat.Mood
        public var pose: BuddyCatPose
        public var blink: Bool
        public var mouthOpen: Bool
        public var listening: Bool
    }

    /// The working reaction stops after this long, like Codex's `running` lifetime.
    public static let workingLifetime: TimeInterval = 3 * 60
    /// While something waits on the user, an ear flicks this often as a reminder.
    public static let waitingReminderInterval: TimeInterval = 30
    /// The greeting wave.
    public static let greetingDuration: TimeInterval = 1.2

    /// True while a reaction, greeting or voice phase is running, so the caller
    /// can raise the frame rate to 20 fps just for that.
    public static func isActive(_ input: Input, now: Date) -> Bool {
        if input.voice != .none { return true }
        if let g = input.greetedAt, now.timeIntervalSince(g) < greetingDuration { return true }
        if let e = input.speakingEndedAt, now.timeIntervalSince(e) < 0.6 { return true }
        return now.timeIntervalSince(input.moodChangedAt) < 3
    }

    public static func frame(_ input: Input, now: Date, reduceMotion: Bool = false) -> Frame {
        let t = now.timeIntervalSince(input.moodChangedAt)
        let clock = now.timeIntervalSinceReferenceDate
        var f = Frame(mood: input.mood, pose: .still, blink: false, mouthOpen: false, listening: false)

        // Voice first: it sits on top of whatever the sessions are doing.
        switch input.voice {
        case .listening:
            f.listening = true
            f.pose.tilt = 2 * ease(t / 0.25)
            f.pose.ring = 1 + 0.03 * sin(tau * clock / 1.2)
            f.blink = blink(clock, period: 4.5)
        case .thinking:
            let side = Int(clock / 0.6) % 2
            f.pose.eyeDx = 1.6
            f.pose.eyeDy = -1
            f.pose.earL = side == 1 ? -10 : 0
            f.pose.earR = side == 1 ? 0 : -10
            f.pose.breath = breath(clock, period: 3.6)
        case .speaking:
            f.mouthOpen = Int(clock / 0.16) % 2 == 0
            f.pose.bob = 0.8 * sin(11 * clock)
        case .none:
            if let e = input.speakingEndedAt, now.timeIntervalSince(e) < 0.5 {
                f.mood = .happy      // a satisfied blink after the reply
                f.pose.breath = breath(clock, period: 3.6)
            } else if let g = input.greetedAt, now.timeIntervalSince(g) < greetingDuration {
                let u = now.timeIntervalSince(g)
                let k = min(1, u / 0.15) * (u > 1 ? 1 - (u - 1) / 0.2 : 1)
                f.pose.tilt = -4 * k
                f.pose.earR = 15 * k * sin(tau * u / 0.4)
            } else {
                f = stateFrame(input.mood, t: t, clock: clock, base: f)
            }
        }

        if reduceMotion {
            var still = BuddyCatPose.still
            still.sweat = f.pose.sweat
            f.pose = still
            f.blink = false
        }
        return f
    }

    // MARK: per-state motion

    private static func stateFrame(_ mood: BuddyCat.Mood, t: TimeInterval, clock: TimeInterval, base: Frame) -> Frame {
        var f = base
        switch mood {
        case .calm:
            f.pose = idle(clock)
            f.blink = blink(clock)
        case .working:
            if t < 2.4 {
                // "Typing": sway, ears alternating, eyes scanning — three passes, easing out.
                let k = 1 - ease((t - 1.9) / 0.5)
                f.pose.dx = 1.2 * k * sin(tau * t / 0.36)
                f.pose.earL = 6 * k * sin(tau * t / 0.36)
                f.pose.earR = 6 * k * sin(tau * t / 0.36)
                f.pose.eyeDx = 1.2 * k * sin(tau * t / 0.72)
            } else if t < workingLifetime {
                f.pose = idle(clock)
                f.pose.eyeDx = 1 * sin(tau * (t - 2.4) / 4)
                f.blink = blink(clock)
            } else {
                f.pose.breath = breath(clock, period: 3.6)
                f.blink = blink(clock)
            }
        case .alert:
            if t < 0.7 {
                f.pose.bob = -6 * abs(sin(.pi * t / 0.35))   // two hops
            } else {
                let u = (t - 0.7).truncatingRemainder(dividingBy: waitingReminderInterval)
                f.pose.breath = breath(clock, period: 3.6, depth: 0.012)
                f.pose.earR = u < 0.4 ? 10 * sin(tau * u / 0.4) : 0
                f.blink = blink(clock, period: 4.1)
            }
        case .wait:
            f.pose.bob = 1.5 * ease(t / 0.8)                  // slump
            f.pose.breath = breath(clock, period: 4.2, depth: 0.01)
            f.blink = clock.truncatingRemainder(dividingBy: 8) > 7.6   // a slow blink
        case .happy:
            if t < 0.5 {
                f.pose.bob = -7 * sin(.pi * t / 0.5)          // one jump
            } else {
                f.pose.tilt = 4 * ease((t - 0.5) / 0.3)
                f.pose.breath = breath(clock, period: 3.6)
            }
        case .worry:
            let k = t < 0.6 ? 1 - t / 0.6 : 0
            f.pose.dx = 2 * k * sin(tau * t / 0.12)           // a decaying shake
            f.pose.sweat = ease((t - 0.2) / 0.4)
            f.pose.breath = breath(clock, period: 4, depth: 0.012)
            f.blink = blink(clock, period: 3.7)
        case .sleep:
            f.pose.breath = breath(clock, period: 5, depth: 0.012)
            f.pose.zA = 0.35 + 0.65 * (0.5 + 0.5 * sin(tau * clock / 2.4))
            f.pose.zB = 0.35 + 0.65 * (0.5 + 0.5 * sin(tau * clock / 2.4 + 2))
        }
        return f
    }

    /// Idle: breathing, and every ~9 s either an ear flick or a small head tilt.
    private static func idle(_ clock: TimeInterval) -> BuddyCatPose {
        var p = BuddyCatPose()
        p.breath = breath(clock, period: 3.6)
        let u = clock.truncatingRemainder(dividingBy: 9)
        if u < 0.5 {
            p.earR = 8 * sin(tau * u / 0.5)
        } else if u > 4.5, u < 5.5 {
            p.tilt = 3 * sin(.pi * (u - 4.5))
        }
        return p
    }

    private static let tau = 2 * Double.pi
    private static func ease(_ x: Double) -> CGFloat { CGFloat(1 - pow(1 - min(max(x, 0), 1), 3)) }
    private static func breath(_ clock: TimeInterval, period: Double, depth: Double = 0.015) -> CGFloat {
        CGFloat(1 + depth * sin(tau * clock / period))
    }
    private static func blink(_ clock: TimeInterval, period: Double = 3.2, length: Double = 0.13) -> Bool {
        clock.truncatingRemainder(dividingBy: period) < length
    }
}
