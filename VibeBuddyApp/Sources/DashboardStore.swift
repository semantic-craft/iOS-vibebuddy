import Foundation
import UIKit
import VibeBuddyKit

/// Consumes the live snapshot stream and publishes grouped sessions, connection
/// state, and notifications. Reconnects automatically when the socket drops.
@MainActor
final class DashboardStore: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var groups = SessionGroups([])
    /// Sessions the user has pointed the buddy at (in-memory, never persisted).
    /// Empty = the buddy sees all sessions; pruned to live IDs on every snapshot.
    @Published private(set) var buddySessionIDs: Set<String> = []
    @Published private(set) var state: ConnectionState = .connecting
    /// Bumped whenever a cue fires, so the buddy can react in step with the sound.
    @Published private(set) var cuePulse = 0
    /// Set when a Live Activity / deep link asks to open a specific session; the
    /// dashboard scrolls to and highlights it, then clears it via `clearFocus()`.
    @Published var focusedSessionId: String?

    private let streamer: SnapshotStreaming
    private let notifier: AttentionNotifier
    private let decisionClient: DecisionClient
    private let liveActivity = LiveActivityManager()
    private var runTask: Task<Void, Never>?
    /// Decides which sound (if any) each snapshot earns. Reset per connection so
    /// the opening backlog of an already-waiting session stays silent.
    private var policy = SoundPolicy()
    private var pairing: PairingPayload?
    private var isDemo = false

    init(streamer: SnapshotStreaming = WebSocketSnapshotClient(),
         notifier: AttentionNotifier = LocalNotifier(),
         decisionClient: DecisionClient = HTTPDecisionClient()) {
        self.streamer = streamer
        self.notifier = notifier
        self.decisionClient = decisionClient
        if ProcessInfo.processInfo.environment["VIBEBUDDY_SKIP_NOTIFICATIONS"] != "1" {
            notifier.requestAuthorization()
        }
    }

    func start(_ pairing: PairingPayload) {
        stop()
        isDemo = false
        self.pairing = pairing
        let phoneName = UIDevice.current.name        // tell the Mac which phone paired
        Task { await Self.sendDeviceName(pairing, name: phoneName) }
        state = .connecting
        policy = SoundPolicy()                        // fresh connection → suppress the backlog
        runTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for await snapshot in self.streamer.stream(pairing) {
                    if Task.isCancelled { return }
                    await self.apply(snapshot)
                }
                if Task.isCancelled { return }
                self.state = .failed(String(localized: "Disconnected — reconnecting…"))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        Task { await liveActivity.end() }
    }

    /// Play the pairing-success cue. Called once when a fresh pairing is saved
    /// (a QR scan or manual connect), not on automatic reconnects.
    func confirmPairing() {
        notifier.confirmPairing()
    }

    /// A flat list of all known sessions, for the voice companion's context.
    var allSessions: [AgentSession] { groups.needsResponse + groups.working + groups.done }

    /// The sessions the buddy is actually grounded in, honouring the scope toggles
    /// (empty selection = all). Read by `VoiceChat`'s contextProvider at call start.
    var buddyContext: [AgentSession] { BuddyScope.included(from: allSessions, selectedIDs: buddySessionIDs) }

    /// Include/exclude a session from the buddy's context (ephemeral). Takes effect
    /// on the next call — a live call keeps the snapshot it started with.
    func toggleBuddy(_ id: String) {
        if buddySessionIDs.contains(id) { buddySessionIDs.remove(id) }
        else { buddySessionIDs.insert(id) }
    }

    /// Execute a voice action on the matching session; returns a spoken confirmation.
    func performVoiceAction(_ action: VoiceAction) -> String {
        switch action {
        case .approve(let project):
            guard let s = match(project), let ap = s.pendingApproval else { return "No session to approve." }
            decide(ap.id, approve: true); return "Approved \(s.project)."
        case .deny(let project):
            guard let s = match(project), let ap = s.pendingApproval else { return "No session to deny." }
            decide(ap.id, approve: false); return "Denied \(s.project)."
        case .answer(let project, let text):
            guard let s = match(project) else { return "No matching session." }
            answer(s.id, answer: text); return "Replied to \(s.project)."
        case .none:
            return ""
        }
    }

    private func match(_ project: String) -> AgentSession? {
        // Conservative resolution (exact-first, unique-substring, refuse ambiguous)
        // so a voice approve never lands on the wrong real command target.
        VoiceSessionMatch.match(project, in: allSessions)
    }

    /// Populate the dashboard with sample sessions and no network, so the app is
    /// reviewable / explorable without a paired Mac.
    func startDemo() {
        stop()
        isDemo = true
        pairing = nil
        state = .connected
        let demo = Self.demoSessions()
        groups = SessionGroups(demo)
        buddySessionIDs = BuddyScope.pruned(buddySessionIDs, toLive: demo)
    }

    func decide(_ approvalId: String, approve: Bool) {
        if isDemo {
            // Resolve locally so a reviewer sees the approval card dismiss.
            let resolved = (groups.needsResponse + groups.working + groups.done).map { s -> AgentSession in
                guard s.pendingApproval?.id == approvalId else { return s }
                var s = s; s.pendingApproval = nil; s.waitKind = nil; s.status = .working
                return s
            }
            groups = SessionGroups(resolved)
            return
        }
        guard let pairing else { return }
        Task { await decisionClient.decide(pairing, approvalId: approvalId, approve: approve) }
    }

    func answer(_ sessionId: String, answer: String) {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isDemo {
            let resolved = (groups.needsResponse + groups.working + groups.done).map { s -> AgentSession in
                guard s.id == sessionId else { return s }
                var s = s
                s.pendingQuestion = nil
                s.waitKind = nil
                s.status = .working
                s.summary = "Answered from phone: \(answer)"
                return s
            }
            groups = SessionGroups(resolved)
            return
        }
        guard let pairing else { return }
        Task { await decisionClient.answer(pairing, sessionId: sessionId, answer: answer) }
    }

    private static func demoSessions() -> [AgentSession] {
        let now = Date()
        return [
            AgentSession(
                id: "demo-edit", agent: .claudeCode, project: "todo-app", branch: "feat/reminders",
                model: "claude-opus-4-8", status: .needsResponse, waitKind: .permission,
                pendingApproval: PendingApproval(
                    id: "demo-ap", tool: "Edit", commandPreview: "src/reminders.ts",
                    filePath: "src/reminders.ts",
                    oldText: "todos.sort((a, b) => a.id - b.id)",
                    newText: "todos.sort((a, b) => a.dueDate - b.dueDate)"),
                summary: "Sort reminders by due date",
                tokens: 4200, contextTokens: 128_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-40), updatedAt: now.addingTimeInterval(-40)),
            AgentSession(
                id: "demo-work", agent: .codex, project: "ios-vibebuddy", branch: "main",
                model: "gpt-5-codex", status: .working, summary: "Running the test suite…",
                tokens: 1500, contextTokens: 64_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-8), updatedAt: now.addingTimeInterval(-8)),
            AgentSession(
                id: "demo-question", agent: .claudeCode, project: "docs-review",
                model: "claude-sonnet-4-5", status: .needsResponse, waitKind: .question,
                pendingQuestion: PendingQuestion(
                    id: "tone",
                    prompt: "Which revision style should I use?",
                    options: [
                        QuestionOption(id: "tight", label: "Tighten", value: "Tighten the draft without changing the argument."),
                        QuestionOption(id: "plain", label: "Plain language", value: "Make it plainer and keep the citations intact."),
                    ]),
                summary: "Which revision style should I use?",
                tokens: 2100, contextTokens: 92_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-24), updatedAt: now.addingTimeInterval(-24)),
            AgentSession(
                id: "demo-done", agent: .claudeCode, project: "docs-site",
                model: "claude-haiku-4-5", status: .done, summary: "Deployed to production.",
                tokens: 900, contextTokens: 20_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-300), updatedAt: now.addingTimeInterval(-300)),
        ]
    }

    /// A brief, self-clearing status line for one-shot actions (e.g. jump result).
    @Published var toast: String?
    private var toastTask: Task<Void, Never>?

    func jump(_ sessionId: String) {
        guard let pairing else { showToast(String(localized: "Couldn't reach your Mac")); return }
        Task {
            let outcome = await decisionClient.jump(pairing, sessionId: sessionId)
            showToast(Self.jumpMessage(outcome))
        }
    }

    /// Honest feedback for a jump — success lands on the Mac, so the phone has to
    /// say so; `nil` means the Mac wasn't reachable.
    static func jumpMessage(_ outcome: JumpOutcome?) -> String {
        switch outcome {
        case .focused:     return String(localized: "Focused the terminal on your Mac")
        case .unsupported: return String(localized: "Can't focus this terminal type yet")
        case .noTerminal:  return String(localized: "No terminal for this session")
        case nil:          return String(localized: "Couldn't reach your Mac")
        }
    }

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            self?.toast = nil
        }
    }

    /// Tell the Mac this phone's name so it can show "Paired: <name>". Best-effort.
    private static func sendDeviceName(_ pairing: PairingPayload, name: String) async {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/device") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(DeviceRegistrationPayload(
            name: name,
            model: UIDevice.current.model,
            systemVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            playSound: SoundPrefs.playSound,
            quietMode: SoundPrefs.effectiveQuiet()
        ))
        _ = try? await URLSession.shared.data(for: request)
    }

    private func apply(_ snapshot: Snapshot) async {
        // The shared policy owns all the sounding rules; we just supply context.
        let alerts = policy.evaluate(SoundPolicyInput(
            sessions: snapshot.sessions,
            now: Date(),
            appActive: UIApplication.shared.applicationState == .active,
            quietMode: SoundPrefs.effectiveQuiet()))
        for alert in alerts {
            notifier.notify(alert)
            Haptics.play(for: alert.sound)   // a tasteful tap to go with the cue
        }
        if !alerts.isEmpty { cuePulse += 1 }   // let the buddy react
        groups = SessionGroups(snapshot.sessions)
        buddySessionIDs = BuddyScope.pruned(buddySessionIDs, toLive: snapshot.sessions)
        state = .connected
        await liveActivity.sync(
            needsResponse: groups.needsResponse.count,
            working: groups.working.count,
            done: groups.done.count,
            topProject: groups.needsResponse.first?.project,
            topSessionId: groups.focusSessionId)
    }

    /// Handle a `vibebuddy://session?id=…` deep link from the Live Activity.
    func open(_ url: URL) {
        guard let id = VibeBuddyDeepLink.sessionId(from: url) else { return }
        focusedSessionId = id
    }

    func clearFocus() { focusedSessionId = nil }
}
