import Foundation

/// Decides whether the microphone should be muted during a realtime voice call.
///
/// We run **half-duplex** (no hardware echo cancellation — ADR-0004): while the
/// model is speaking we stop forwarding mic audio so it never hears its own voice.
/// The subtlety this type encodes: the mic must stay muted for the *entire* model
/// turn, and re-open only once the turn is **complete** AND the queued audio has
/// **drained**. Un-muting on a transient mid-turn playback drain (a network gap
/// between audio chunks) leaks the model's echo back into the provider's VAD,
/// which then thinks the user interrupted and cancels the response — the Gemini
/// "speaks a few words then stops" bug.
public struct HalfDuplexGate: Sendable, Equatable {
    public private(set) var micMuted: Bool = false

    private var speaking = false      // model is mid-turn (has emitted audio, not yet done+drained)
    private var turnComplete = true   // provider signalled the turn finished
    private var drained = true        // playback queue is empty

    public init() {}

    /// A chunk of model audio arrived → mute the mic and (re)enter the turn.
    public mutating func modelAudioReceived() {
        speaking = true
        turnComplete = false
        drained = false
        micMuted = true
    }

    /// The provider signalled the model's turn is complete (`responseDone`).
    public mutating func turnDidComplete() {
        turnComplete = true
        reopenIfFinished()
    }

    /// The playback queue emptied. Fires on transient mid-turn gaps too, so it
    /// only re-opens the mic when the turn is also complete.
    public mutating func playbackDrained() {
        drained = true
        reopenIfFinished()
    }

    private mutating func reopenIfFinished() {
        guard speaking, turnComplete, drained else { return }
        speaking = false
        micMuted = false
    }
}
