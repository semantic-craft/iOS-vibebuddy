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
    var micMuted: Bool { get set }
    func enqueue(_ pcm: Data)
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
    private let closeSession: () -> Void
    private var gate = HalfDuplexGate()
    private var assistantBuffer = ""
    private var toolTasks: [String: Task<Void, Never>] = [:]
    private var handledToolIDs: Set<String> = []
    private var stopped = false

    public init(
        audio: any VoiceCallAudio,
        actionHandler: @escaping (VoiceAction) async -> String,
        sendToolResult: @escaping (String, String, String) -> Void = { _, _, _ in },
        closeSession: @escaping () -> Void = {}
    ) {
        self.audio = audio
        self.actionHandler = actionHandler
        self.sendToolResult = sendToolResult
        self.closeSession = closeSession
    }

    public func beginConnecting() {
        phase = .connecting
    }

    public func handle(_ event: RealtimeVoiceEvent) {
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
        case .audioDelta(let pcm):
            gate.modelAudioReceived()
            audio.micMuted = gate.micMuted
            phase = .speaking
            audio.enqueue(pcm)
        case .responseDone:
            gate.turnDidComplete()
            updateMicAfterGateChange()
        case .toolCall(let name, let arguments, let callID):
            let action = VoiceTools.action(name: name, arguments: arguments)
            guard !stopped, handledToolIDs.insert(callID).inserted else { return }
            phase = .thinking
            toolTasks[callID] = Task { [weak self] in
                guard let self else { return }
                let result = action == .none ? "Sorry, I couldn't do that." : await actionHandler(action)
                guard !Task.isCancelled, !stopped else { return }
                if action != .none { lastReply = result }
                sendToolResult(callID, name, result)
                toolTasks[callID] = nil
            }
        case .failed(let message):
            errorText = message
            stop()
        case .closed:
            stop()
        case .speechStarted:
            break
        }
    }

    public func stop() {
        stopped = true
        toolTasks.values.forEach { $0.cancel() }
        toolTasks.removeAll()
        audio.stop()
        audio.micMuted = false
        gate = HalfDuplexGate()
        closeSession()
        phase = .idle
    }

    public func playbackDrained() {
        gate.playbackDrained()
        updateMicAfterGateChange()
    }

    private func updateMicAfterGateChange() {
        audio.micMuted = gate.micMuted
        if !gate.micMuted, phase == .speaking {
            phase = .listening
        }
    }
}
