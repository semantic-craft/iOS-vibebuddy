import Foundation

/// Only the display-safe facts needed to recognize a followed session.
public struct WatchFollowedTask: Codable, Equatable, Sendable, Identifiable {
    public var sessionID: String
    public var completionID: String?
    public var title: String
    public var summary: String?
    public var presentation: TaskPresentationState
    public var statusSince: Date
    public var id: String { sessionID }

    public init(_ session: AgentSession) {
        sessionID = session.id
        completionID = session.completionID
        title = String(session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        // A request can contain a full command, path or question. The compact
        // surface sends its category only; details stay in existing alert UI.
        let text = session.status == .needsResponse ? nil : session.summary
        summary = text.flatMap { raw in
            let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            // Conservative: do not place path/command-shaped summaries on a face.
            guard !line.contains("/"), !line.contains("\\"), !line.contains("`"),
                  !line.contains("$") else { return nil }
            return String(line.prefix(100))
        }
        // Explicit input wins over error on this surface (the PRD's proposed
        // default); retain the shared presentation vocabulary and color tokens.
        presentation = session.status == .needsResponse ? .requiresInput :
            TaskPresentationState.project(status: session.status, waitKind: session.waitKind,
                failed: session.failed == true, hasUnreadCompletion: session.hasUnreadCompletion)
        statusSince = session.statusSince
    }

    public var isCandidate: Bool { presentation != .idle && presentation != .unassigned }
    private var rank: Int {
        switch presentation {
        case .requiresInput: 0
        case .error: 1
        case .completeUnread: 2
        case .thinking: 3
        default: 4
        }
    }

    public static func select(from tasks: [Self], keeping sessionID: String? = nil) -> Self? {
        let sorted = tasks.filter(\.isCandidate).sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.statusSince != $1.statusSince { return $0.statusSince < $1.statusSince }
            return $0.sessionID < $1.sessionID
        }
        guard let first = sorted.first else { return nil }
        if first.presentation == .thinking,
           let retained = sorted.first(where: { $0.sessionID == sessionID && $0.presentation == .thinking }) {
            return retained
        }
        return first
    }
}

/// Separate from the app's richer alert cache: no full requests reach WidgetKit.
public struct WatchComplicationSnapshot: Codable, Equatable, Sendable {
    public var sourceID: String?
    public var pairingEpoch: String?
    public var tasks: [WatchFollowedTask]
    public var selectedSessionID: String?
    public var pendingCompletionIDs: [String] = []
    public var observedAt: Date
    public var relay: WatchRelayState
    public var selectedTask: WatchFollowedTask? {
        guard sourceID != nil else { return nil }
        return WatchFollowedTask.select(from: tasks, keeping: selectedSessionID)
    }
    public var otherCount: Int { max(0, tasks.filter(\.isCandidate).count - 1) }

    public init(state: WatchDashboardState, previous: Self? = nil) {
        sourceID = state.sourceID
        pairingEpoch = state.pairingEpoch
        tasks = state.followedTasks
        observedAt = state.observedAt
        relay = state.relay
        let retained = previous?.sourceID == sourceID && previous?.pairingEpoch == pairingEpoch
            ? previous?.selectedSessionID : nil
        selectedSessionID = WatchFollowedTask.select(from: tasks, keeping: retained)?.sessionID
    }
}
