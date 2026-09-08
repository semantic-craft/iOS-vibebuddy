import Foundation

/// Shared realtime voice-call state. Platform code supplies the audio adapter;
/// this coordinator owns provider events that should behave the same on iOS and Mac.
public enum VoiceCallPhase: Equatable, Sendable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
}

@MainActor
public protocol VoiceCallAudio: AnyObject {
    var isPlaybackPending: Bool { get }
    func flushPlayback() -> [VoicePlaybackCheckpoint]
    func enqueue(_ pcm: Data, item: VoiceAudioItem?)
    func stop()
}

@MainActor
public final class VoiceCallCoordinator {
    public private(set) var phase: VoiceCallPhase = .idle
    public private(set) var lastUserText = ""
    public private(set) var lastReply = ""
    public private(set) var errorText: String?

    private let audio: any VoiceCallAudio
    private let actionHandler: (VoiceAction) async -> String
    private let sendToolResult: (String, String, String) -> Void
    private let truncatePlayback: ([VoicePlaybackCheckpoint]) -> Void
    private let closeSession: () -> Void
    private var turnComplete = true
    private var assistantBuffer = ""
    private var toolTasks: [String: Task<Void, Never>] = [:]
    private var handledToolIDs: Set<String> = []
    private var stopped = false

    public init(
        audio: any VoiceCallAudio,
        actionHandler: @escaping (VoiceAction) async -> String,
        sendToolResult: @escaping (String, String, String) -> Void = { _, _, _ in },
        truncatePlayback: @escaping ([VoicePlaybackCheckpoint]) -> Void = { _ in },
        closeSession: @escaping () -> Void = {}
    ) {
        self.audio = audio
        self.actionHandler = actionHandler
        self.sendToolResult = sendToolResult
        self.closeSession = closeSession
        self.truncatePlayback = truncatePlayback
    }

    public func beginConnecting() {
        phase = .connecting
    }

    public func handle(_ event: RealtimeVoiceEvent) {
        guard !stopped else { return }
        switch event {
        case .connected:
            phase = .listening
        case .userTranscript(let text, _):
            lastUserText = text
            if VoiceCloseIntent.shouldClose(text) { stop() }
        case .assistantTranscript(let text, let final):
            if final {
                lastReply = text
                assistantBuffer = ""
            } else {
                assistantBuffer += text
                lastReply = assistantBuffer
            }
        case .audioDelta(let pcm, let item):
            turnComplete = false
            phase = .speaking
            audio.enqueue(pcm, item: item)
        case .responseDone:
            turnComplete = true
            updatePlaybackPhase()
        case .toolCall(let name, let arguments, let callID):
            let action = VoiceTools.action(name: name, arguments: arguments)
            guard !stopped, handledToolIDs.insert(callID).inserted else { return }
            phase = .thinking
            toolTasks[callID] = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                let result = action == .none ? "Sorry, I couldn't do that." : await actionHandler(action)
                guard !Task.isCancelled, !stopped else { return }
                if action != .none { lastReply = result }
                sendToolResult(callID, name, result)
                toolTasks[callID] = nil
            }
        case .toolCallsCancelled(let ids):
            for id in ids {
                handledToolIDs.insert(id)
                toolTasks.removeValue(forKey: id)?.cancel()
            }
        case .failed(let message):
            errorText = message
            stop()
        case .closed:
            stop()
        case .speechStarted:
            truncatePlayback(audio.flushPlayback())
            assistantBuffer = ""
            turnComplete = true
            phase = .listening
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        toolTasks.values.forEach { $0.cancel() }
        toolTasks.removeAll()
        audio.stop()
        turnComplete = true
        closeSession()
        phase = .idle
    }

    public func playbackDrained() {
        guard !stopped else { return }
        updatePlaybackPhase()
    }

    private func updatePlaybackPhase() {
        if turnComplete, !audio.isPlaybackPending, phase == .speaking {
            phase = .listening
        }
    }
}
