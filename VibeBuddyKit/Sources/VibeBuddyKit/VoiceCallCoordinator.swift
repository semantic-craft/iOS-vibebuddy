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
    /// Terminal: the call ended for a reason the UI explains and can redial from.
    case ended(VoiceCallEndReason)
}

/// Why a call ended on its own, when the person should be told and offered a
/// redial. A user hangup or a failure is not one of these (`.idle` / `errorText`).
public enum VoiceCallEndReason: Equatable, Sendable {
    /// The provider's per-connection limit was reached. Redial opens a fresh
    /// session with the same Settings; nothing from this call carries over.
    case providerLimit

    public func notice(provider: VoiceProvider) -> String {
        switch self {
        case .providerLimit:
            String(localized: "Call ended: \(provider.display) reached its per-call time limit. Redial starts a new call without this conversation.", bundle: .module)
        }
    }
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
    /// A task action the user's words did not name, held instead of sent
    /// (RV-03). Cleared when a later task action is sent or the call stops.
    public private(set) var heldNotice: String?
    public var endReason: VoiceCallEndReason? {
        if case .ended(let reason) = phase { return reason }
        return nil
    }
    /// Stopped for any reason; late provider events no longer change anything.
    public var isFinished: Bool { stopped }

    private let audio: any VoiceCallAudio
    private let actionHandler: (VoiceAction) async -> String
    private let sendToolResult: (String, String, String) -> Void
    private let truncatePlayback: ([VoicePlaybackCheckpoint]) -> Void
    private let closeSession: (VoiceToolResult?) -> Void
    private let continuousPlayback: Bool
    private let contextProvider: (() -> [AgentSession])?
    private let statusContextProvider: (@MainActor () async -> [AgentSession])?
    private var userFragments: [VoiceTranscriptFragment] = []
    private var assistantFragments: [VoiceTranscriptFragment] = []
    private var turnComplete = true
    private var assistantBuffer = ""
    private var toolTasks: [String: Task<Void, Never>] = [:]
    private var handledToolIDs: Set<String> = []
    private var recoveringAudio = false
    private var stopped = false
    private var closeIntentTask: Task<Void, Never>?
    /// What the user was heard saying in the current exchange: every user
    /// transcript or caption since the companion last produced output. Only a
    /// veto for task actions (VoiceTargetCheck), never an authorization.
    private var heardWords = ""
    private var companionSpokeSinceUser = false
    private let transcriptGrace: Duration
    public private(set) var endedByExplicitVoiceCommand = false

    public init(
        audio: any VoiceCallAudio,
        actionHandler: @escaping (VoiceAction) async -> String,
        sendToolResult: @escaping (String, String, String) -> Void = { _, _, _ in },
        truncatePlayback: @escaping ([VoicePlaybackCheckpoint]) -> Void = { _ in },
        closeSession: @escaping (VoiceToolResult?) -> Void = { _ in },
        continuousPlayback: Bool = false,
        contextProvider: (() -> [AgentSession])? = nil,
        statusContextProvider: (@MainActor () async -> [AgentSession])? = nil,
        transcriptGrace: Duration = .milliseconds(2500)
    ) {
        self.audio = audio
        self.actionHandler = actionHandler
        self.sendToolResult = sendToolResult
        self.closeSession = closeSession
        self.truncatePlayback = truncatePlayback
        self.continuousPlayback = continuousPlayback
        self.contextProvider = contextProvider
        self.statusContextProvider = statusContextProvider
        self.transcriptGrace = transcriptGrace
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
            heard(text)
            if final, VoiceCloseIntent.isExplicitCallEnd(text) {
                endedByExplicitVoiceCommand = true
                stop()
            }
        case .transcriptFragment(let fragment):
            // Retain a bounded window for each speaker, including overlap and
            // late fragments. Captions never authorize coding actions. A narrow
            // settled call-ending command controls this local voice session only.
            if fragment.speaker == .user {
                heard(fragment.text)
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
                companionSpokeSinceUser = true
                assistantFragments.append(fragment)
                assistantFragments = Array(assistantFragments.suffix(128))
                lastReply = Self.caption(assistantFragments)
            }
        case .assistantTranscript(let text, let final):
            companionSpokeSinceUser = true
            if final {
                lastReply = text
                assistantBuffer = ""
            } else {
                assistantBuffer += text
                lastReply = assistantBuffer
            }
        case .audioDelta(let pcm, let item):
            guard !recoveringAudio else { return }
            companionSpokeSinceUser = true
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
                    let sessions = await statusContextProvider?() ?? contextProvider?() ?? []
                    result = VoicePrompt.sessionContext(sessions)
                } else if name == VoiceTools.endCall.name, object?.isEmpty == true {
                    stop(completingTool: VoiceToolResult(callID: callID, name: name, result: "Voice call ending; coding tasks are unchanged."))
                    return
                } else if action != .none, let contextProvider,
                          let project = object?["project"] as? String,
                          VoiceSessionMatch.match(project, in: contextProvider()) == nil {
                    result = "No unique matching task in the user's selected voice scope; no action was sent."
                } else if let project = action.taskTarget,
                          let held = await holdUnlessNamed(project) {
                    guard !Task.isCancelled, !stopped else { return }
                    heldNotice = held.notice
                    result = held.result
                } else {
                    if action.taskTarget != nil { heldNotice = nil }
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
        case .providerLimitReached:
            stop()
            phase = .ended(.providerLimit)
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
        heldNotice = nil
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

    private func heard(_ text: String) {
        if companionSpokeSinceUser {
            heardWords = ""
            companionSpokeSinceUser = false
        }
        heardWords = String((heardWords + " " + text).suffix(2000))
    }

    /// Nil when the user's words name the action's target. Otherwise the
    /// action is held: the tool result tells the model why and what the user
    /// must say, and the notice is shown on screen. Transcription can arrive
    /// after the tool call (Qwen: 0.1–0.7 s), so wait briefly for it first.
    private func holdUnlessNamed(_ project: String) async -> (result: String, notice: String)? {
        let scope = contextProvider?()
        let target = scope.flatMap { VoiceSessionMatch.match(project, in: $0) }
        func check() -> VoiceTargetCheck.Verdict {
            if let target, let scope {
                return VoiceTargetCheck.verdict(target: target, heard: heardWords, scope: scope)
            }
            return VoiceTargetCheck.verdict(project: project, heard: heardWords)
        }
        var verdict = check()
        let deadline = ContinuousClock.now + transcriptGrace
        while verdict != .named, ContinuousClock.now < deadline, !Task.isCancelled, !stopped {
            try? await Task.sleep(for: .milliseconds(100))
            verdict = check()
        }
        let name = target?.displayTitle ?? project
        switch verdict {
        case .named:
            return nil
        case .namedOther(let other):
            return ("Not sent: the user named \(other), not \(name); nothing was sent to \(name). Tell the user, and act only on the task they name.",
                    String(localized: "Not sent to \(name): you said \(other).", bundle: .module))
        case .unnamed:
            return ("Not sent: the user's words did not name \(name), so nothing was sent. Say which task you would act on and ask the user to say its name; call the tool again only after they say it.",
                    String(localized: "Not sent to \(name): say “\(name)” to confirm.", bundle: .module))
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
