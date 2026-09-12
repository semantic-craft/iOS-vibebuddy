import Foundation

/// Shared realtime voice-call state. Platform code supplies the audio adapter;
/// this coordinator owns provider events that should behave the same on iOS and Mac.
public enum VoiceCallPhase: Equatable, Sendable {
    case idle
    case connecting
    case recovering
    case listening
    case thinking
    case speaking
}

/// Actual audio availability, independent of provider connection status.
public enum VoiceCallAudioState: Equatable, Sendable {
    case running
    case recovering
    case failed(String)
}

@MainActor
public protocol VoiceCallAudio: AnyObject {
    var isPlaybackPending: Bool { get }
    var isAudiblePlaybackPending: Bool { get }
    func flushPlayback() -> [VoicePlaybackCheckpoint]
    func enqueue(_ pcm: Data, item: VoiceAudioItem?)
    func stop()
}

public extension VoiceCallAudio {
    var isAudiblePlaybackPending: Bool { isPlaybackPending }
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
    private let closeSession: (VoiceToolResult?) -> Void
    private let continuousPlayback: Bool
    private let contextProvider: (() -> [AgentSession])?
    private var userFragments: [VoiceTranscriptFragment] = []
    private var assistantFragments: [VoiceTranscriptFragment] = []
    private var turnComplete = true
    private var assistantBuffer = ""
    private var toolTasks: [String: Task<Void, Never>] = [:]
    private var handledToolIDs: Set<String> = []
    private var recoveringAudio = false
    private var stopped = false
    private var closeIntentTask: Task<Void, Never>?
    public private(set) var endedByExplicitVoiceCommand = false

    public init(
        audio: any VoiceCallAudio,
        actionHandler: @escaping (VoiceAction) async -> String,
        sendToolResult: @escaping (String, String, String) -> Void = { _, _, _ in },
        truncatePlayback: @escaping ([VoicePlaybackCheckpoint]) -> Void = { _ in },
        closeSession: @escaping (VoiceToolResult?) -> Void = { _ in },
        continuousPlayback: Bool = false,
        contextProvider: (() -> [AgentSession])? = nil
    ) {
        self.audio = audio
        self.actionHandler = actionHandler
        self.sendToolResult = sendToolResult
        self.closeSession = closeSession
        self.truncatePlayback = truncatePlayback
        self.continuousPlayback = continuousPlayback
        self.contextProvider = contextProvider
    }

    public func beginConnecting() {
        phase = .connecting
    }

    public func audioStateChanged(_ state: VoiceCallAudioState) {
        guard !stopped else { return }
        switch state {
        case .recovering:
            recoveringAudio = true
            truncatePlayback(audio.flushPlayback())
            turnComplete = true
            phase = .recovering
        case .running:
            recoveringAudio = false
            phase = toolTasks.isEmpty ? .listening : .thinking
        case .failed(let message):
            errorText = message
            stop()
        }
    }

    public func handle(_ event: RealtimeVoiceEvent) {
        guard !stopped else { return }
        defer { if recoveringAudio, !stopped { phase = .recovering } }
        switch event {
        case .connected:
            phase = !recoveringAudio ? .listening : .recovering
        case .userTranscript(let text, let final):
            lastUserText = text
            if final, VoiceCloseIntent.isExplicitCallEnd(text) {
                endedByExplicitVoiceCommand = true
                stop()
            }
        case .transcriptFragment(let fragment):
            // Retain a bounded window for each speaker, including overlap and
            // late fragments. Captions never authorize coding actions. A narrow
            // settled call-ending command controls this local voice session only.
            if fragment.speaker == .user {
                userFragments.append(fragment)
                userFragments = Array(userFragments.suffix(128))
                lastUserText = Self.caption(userFragments)
                closeIntentTask?.cancel()
                closeIntentTask = nil
                if continuousPlayback, VoiceCloseIntent.isExplicitCallEnd(lastUserText) {
                    closeIntentTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(750))
                        guard !Task.isCancelled, let self, !self.stopped,
                              VoiceCloseIntent.isExplicitCallEnd(self.lastUserText) else { return }
                        self.endedByExplicitVoiceCommand = true
                        self.stop()
                    }
                }
            } else {
                assistantFragments.append(fragment)
                assistantFragments = Array(assistantFragments.suffix(128))
                lastReply = Self.caption(assistantFragments)
            }
        case .assistantTranscript(let text, let final):
            if final {
                lastReply = text
                assistantBuffer = ""
            } else {
                assistantBuffer += text
                lastReply = assistantBuffer
            }
        case .audioDelta(let pcm, let item):
            guard !recoveringAudio else { return }
            turnComplete = continuousPlayback
            audio.enqueue(pcm, item: item)
            guard !recoveringAudio, !stopped else { return }
            if !continuousPlayback || audio.isAudiblePlaybackPending { phase = .speaking }
            else { updatePlaybackPhase() }
        case .responseDone:
            turnComplete = true
            updatePlaybackPhase()
        case .toolCall(let name, let arguments, let callID):
            let action = VoiceTools.action(name: name, arguments: arguments)
            guard !stopped, handledToolIDs.insert(callID).inserted else { return }
            let playing = continuousPlayback ? audio.isAudiblePlaybackPending : audio.isPlaybackPending
            phase = !recoveringAudio ? (playing ? .speaking : .thinking) : .recovering
            toolTasks[callID] = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                let result: String
                let object = arguments.data(using: .utf8).flatMap {
                    (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
                }
                if name == VoiceTools.status.name, object?.isEmpty == true {
                    result = VoicePrompt.sessionContext(contextProvider?() ?? [])
                } else if name == VoiceTools.endCall.name, object?.isEmpty == true {
                    stop(completingTool: VoiceToolResult(callID: callID, name: name, result: "Voice call ending; coding tasks are unchanged."))
                    return
                } else if action != .none, let contextProvider,
                          let project = object?["project"] as? String,
                          VoiceSessionMatch.match(project, in: contextProvider()) == nil {
                    result = "No unique matching task in the user's selected voice scope; no action was sent."
                } else {
                    result = action == .none ? "Sorry, I couldn't do that." : await actionHandler(action)
                }
                guard !Task.isCancelled, !stopped else { return }
                if action != .none, !continuousPlayback { lastReply = result }
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
            toolTasks.values.forEach { $0.cancel() }
            toolTasks.removeAll()
            truncatePlayback(audio.flushPlayback())
            assistantBuffer = ""
            turnComplete = true
            phase = !recoveringAudio ? .listening : .recovering
        }
    }

    public func stop(completingTool: VoiceToolResult? = nil) {
        guard !stopped else { return }
        stopped = true
        closeIntentTask?.cancel(); closeIntentTask = nil
        toolTasks.values.forEach { $0.cancel() }
        toolTasks.removeAll()
        audio.stop()
        turnComplete = true
        closeSession(completingTool)
        phase = .idle
    }

    public func playbackDrained() {
        guard !stopped, !recoveringAudio else { return }
        if continuousPlayback, audio.isAudiblePlaybackPending { phase = .speaking }
        updatePlaybackPhase()
    }

    private func updatePlaybackPhase() {
        guard !recoveringAudio else { phase = .recovering; return }
        let pending = continuousPlayback ? audio.isAudiblePlaybackPending : audio.isPlaybackPending
        if turnComplete, !pending, phase == .speaking {
            phase = toolTasks.isEmpty ? .listening : .thinking
        }
    }

    private static func caption(_ fragments: [VoiceTranscriptFragment]) -> String {
        // Show the latest same-speaker group; the 1.5s gap is a UI grouping
        // heuristic only. Keep the original fragments so late text can regroup.
        let ordered = fragments.enumerated().sorted {
            if $0.element.startMilliseconds == $1.element.startMilliseconds { return $0.offset < $1.offset }
            return $0.element.startMilliseconds < $1.element.startMilliseconds
        }.map(\.element)
        var text = ""
        var end: Int?
        for fragment in ordered {
            if let end, fragment.startMilliseconds - end > 1500 { text = "" }
            text += fragment.text
            end = max(end ?? 0, fragment.endMilliseconds)
        }
        return String(text.suffix(4096))
    }
}
