import Testing
@testable import VibeBuddyKit

@Suite("HalfDuplexGate — mic stays muted for the whole model turn")
struct HalfDuplexGateTests {

    @Test("starts un-muted so the user can speak")
    func startsOpen() {
        let gate = HalfDuplexGate()
        #expect(gate.micMuted == false)
    }

    @Test("mutes the mic as soon as the model starts speaking")
    func mutesOnModelAudio() {
        var gate = HalfDuplexGate()
        gate.modelAudioReceived()
        #expect(gate.micMuted == true)
    }

    /// The bug: a momentary playback drain *between* audio chunks mid-sentence
    /// must NOT re-open the mic (that leaked the model's echo into Gemini's VAD).
    @Test("a transient mid-turn playback drain does not un-mute")
    func transientDrainKeepsMuted() {
        var gate = HalfDuplexGate()
        gate.modelAudioReceived()
        gate.playbackDrained()          // network gap between chunks, turn NOT complete
        #expect(gate.micMuted == true)
        gate.modelAudioReceived()       // next chunk arrives
        #expect(gate.micMuted == true)
    }

    @Test("un-mutes only after the turn completes AND playback drains")
    func unmutesAfterCompleteAndDrained() {
        var gate = HalfDuplexGate()
        gate.modelAudioReceived()
        gate.turnDidComplete()          // server done generating, audio still playing
        #expect(gate.micMuted == true)
        gate.playbackDrained()          // audio finished playing out
        #expect(gate.micMuted == false)
    }

    @Test("handles the drain arriving before turn-complete")
    func drainBeforeComplete() {
        var gate = HalfDuplexGate()
        gate.modelAudioReceived()
        gate.playbackDrained()          // mid-turn — stays muted
        gate.turnDidComplete()          // now complete, and already drained → open
        #expect(gate.micMuted == false)
    }

    @Test("a new turn re-mutes the mic")
    func newTurnRemutes() {
        var gate = HalfDuplexGate()
        gate.modelAudioReceived(); gate.turnDidComplete(); gate.playbackDrained()
        #expect(gate.micMuted == false)
        gate.modelAudioReceived()
        #expect(gate.micMuted == true)
    }

    @Test("a text-only turn with no audio leaves the mic open")
    func textOnlyTurnStaysOpen() {
        var gate = HalfDuplexGate()
        gate.turnDidComplete()          // turn completed, model never spoke
        #expect(gate.micMuted == false)
    }
}
