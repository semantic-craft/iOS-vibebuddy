import Foundation
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
    @Published private(set) var state: ConnectionState = .connecting

    private let streamer: SnapshotStreaming
    private let notifier: AttentionNotifier
    private let decisionClient: DecisionClient
    private let liveActivity = LiveActivityManager()
    private var runTask: Task<Void, Never>?
    private var lastSessions: [AgentSession] = []
    private var seenFirstSnapshot = false
    private var pairing: PairingPayload?
    private var isDemo = false

    init(streamer: SnapshotStreaming = WebSocketSnapshotClient(),
         notifier: AttentionNotifier = LocalNotifier(),
         decisionClient: DecisionClient = HTTPDecisionClient()) {
        self.streamer = streamer
        self.notifier = notifier
        self.decisionClient = decisionClient
        notifier.requestAuthorization()
    }

    func start(_ pairing: PairingPayload) {
        stop()
        self.pairing = pairing
        state = .connecting
        lastSessions = []
        seenFirstSnapshot = false
        runTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for await snapshot in self.streamer.stream(pairing) {
                    if Task.isCancelled { return }
                    await self.apply(snapshot)
                }
                if Task.isCancelled { return }
                self.state = .failed("连接断开,重连中…")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        Task { await liveActivity.end() }
    }

    /// Populate the dashboard with sample sessions and no network, so the app is
    /// reviewable / explorable without a paired Mac.
    func startDemo() {
        stop()
        isDemo = true
        pairing = nil
        state = .connected
        groups = SessionGroups(Self.demoSessions())
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

    private static func demoSessions() -> [AgentSession] {
        let now = Date()
        return [
            AgentSession(
                id: "demo-edit", agent: .claudeCode, project: "payments-api", branch: "feat/refunds",
                model: "claude-opus-4-8", status: .needsResponse, waitKind: .permission,
                pendingApproval: PendingApproval(
                    id: "demo-ap", tool: "Edit", commandPreview: "src/refund.ts",
                    filePath: "src/refund.ts",
                    oldText: "const fee = 0.3\nreturn amount - fee",
                    newText: "const fee = amount * 0.029 + 0.3\nreturn amount - fee"),
                summary: "Apply a Stripe-style processing fee",
                tokens: 4200, contextTokens: 128_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-40), updatedAt: now.addingTimeInterval(-40)),
            AgentSession(
                id: "demo-work", agent: .codex, project: "ios-vibebuddy", branch: "main",
                model: "gpt-5-codex", status: .working, summary: "Running the test suite…",
                tokens: 1500, contextTokens: 64_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-8), updatedAt: now.addingTimeInterval(-8)),
            AgentSession(
                id: "demo-done", agent: .claudeCode, project: "docs-site",
                model: "claude-haiku-4-5", status: .done, summary: "Deployed to production.",
                tokens: 900, contextTokens: 20_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-300), updatedAt: now.addingTimeInterval(-300)),
        ]
    }

    func jump(_ sessionId: String) {
        guard let pairing else { return }
        Task { await decisionClient.jump(pairing, sessionId: sessionId) }
    }

    private func apply(_ snapshot: Snapshot) async {
        // Notify only on a fresh transition into needsResponse; lastSessions
        // persists across reconnects so the already-waiting set isn't re-fired.
        if seenFirstSnapshot {
            for session in AttentionDiff.newlyNeedingResponse(
                old: lastSessions, new: snapshot.sessions) {
                notifier.notify(session)
            }
        }
        lastSessions = snapshot.sessions
        seenFirstSnapshot = true
        groups = SessionGroups(snapshot.sessions)
        state = .connected
        await liveActivity.sync(
            needsResponse: groups.needsResponse.count,
            working: groups.working.count,
            done: groups.done.count,
            topProject: groups.needsResponse.first?.project)
    }
}
