import Foundation
import OSLog
import VibeBuddyKit
import WatchKit

/// Plays a wrist rhythm. The Kit decided *what* to say and *whether* to say it
/// (`WatchHaptics`); this only turns a sequence of beats into taps, spaced far
/// enough apart that the count survives.
///
/// Every decision is logged, including the silent ones, because the Simulator
/// has no haptics at all: `log stream --predicate 'subsystem == "com.vibebuddy.watch"'`
/// is the only way to see that the right rhythm was asked for.
@MainActor
final class WatchHapticPlayer {
    static let shared = WatchHapticPlayer()

    static let subsystem = "com.vibebuddy.watch"
    private static let log = Logger(subsystem: subsystem, category: "haptics")

    /// The rhythm currently being tapped out. A newer one replaces it rather
    /// than interleaving with it — two rhythms at once are unreadable.
    private var playing: Task<Void, Never>?

    private let device: WKInterfaceDevice

    init(device: WKInterfaceDevice = .current()) {
        self.device = device
    }

    /// `reason` names the transition in the log; it is never shown to anyone.
    func play(_ beats: [WristHapticBeat], reason: String) {
        guard !beats.isEmpty else {
            Self.log.info("wrist silent (\(reason, privacy: .public))")
            return
        }
        let pattern = beats.map(\.rawValue).joined(separator: "-")
        Self.log.info("wrist haptic \(pattern, privacy: .public) (\(reason, privacy: .public))")
        playing?.cancel()
        playing = Task { @MainActor [device] in
            for (index, beat) in beats.enumerated() {
                if Task.isCancelled { return }
                device.play(beat.hapticType)
                guard index < beats.count - 1 else { break }
                try? await Task.sleep(for: .seconds(beat.spacing))
            }
        }
    }
}

extension WristHapticBeat {
    /// watchOS offers only canned taps, so the rhythm carries the meaning and
    /// each beat just has to be distinguishable from the other kind: `click` is
    /// the lightest tap there is, `directionUp` a noticeably heavier one.
    var hapticType: WKHapticType {
        switch self {
        case .short: return .click
        case .long:  return .directionUp
        }
    }
}
