import Foundation

/// Hardware availability is independent from a model response or tool turn.
public enum VoiceAudioAvailability: Equatable, Sendable {
    case available
    case recovering
    case interrupted
    case failed(String)
}
