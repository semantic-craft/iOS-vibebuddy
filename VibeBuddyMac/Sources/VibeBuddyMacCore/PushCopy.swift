import Foundation
import VibeBuddyKit

/// Banner copy for a push about one session, mirroring the phone's own local
/// notification word for word (`Notifier.copy(for:)` in the iOS app).
///
/// The Mac cannot know the phone's language, so alongside the English `title`
/// / `body` it names the phone's string-table keys (`title-loc-key`,
/// `loc-key`) and lets the phone localize. The keys are the English source text
/// (development language = en), so a phone without a matching table shows the
/// same English the local notification would.
public struct PushCopy: Equatable, Sendable {
    public var title: String
    public var body: String
    /// The phone's key for `title`, formatted with `titleArgs`.
    public var titleKey: String
    public var titleArgs: [String]
    /// The phone's key for `body` when the body is fixed copy; nil when it is
    /// free text (a command preview, a summary) that needs no translation.
    public var bodyKey: String?

    public init(title: String, body: String, titleKey: String, titleArgs: [String], bodyKey: String?) {
        self.title = title
        self.body = body
        self.titleKey = titleKey
        self.titleArgs = titleArgs
        self.bodyKey = bodyKey
    }

    /// The copy the phone would put on its own banner for this cue.
    public static func copy(for sound: NotificationSound, session s: AgentSession) -> PushCopy {
        func make(_ titleKey: String, fixed: String, free: String?) -> PushCopy {
            let title = titleKey.replacingOccurrences(of: "%@", with: s.project)
            if let free {
                return PushCopy(title: title, body: free, titleKey: titleKey, titleArgs: [s.project], bodyKey: nil)
            }
            return PushCopy(title: title, body: fixed, titleKey: titleKey, titleArgs: [s.project], bodyKey: fixed)
        }
        switch sound {
        case .needsApproval:
            return make("%@ needs permission", fixed: "Approve or deny",
                        free: s.pendingApproval?.commandPreview ?? s.summary)
        case .needsAnswer:
            return make("%@ needs you", fixed: "Waiting for your input", free: s.summary)
        case .longWaitNudge:
            return make("%@ is still waiting", fixed: "Waiting for your input", free: s.summary)
        case .agentDone:
            return make("%@ is done", fixed: "Task complete", free: s.summary)
        case .agentStuck:
            return make("%@ stopped", fixed: "Might need a look", free: s.summary)
        case .pairSuccess:
            return PushCopy(title: "Connected", body: "VibeBuddy is watching your sessions.",
                            titleKey: "Connected", titleArgs: [],
                            bodyKey: "VibeBuddy is watching your sessions.")
        }
    }
}
