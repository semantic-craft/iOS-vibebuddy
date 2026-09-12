import Foundation

/// One queued follow-up per Cursor conversation, handed to Cursor's own `stop`
/// hook when the turn ends.
///
/// Cursor has no way to inject text into a running turn — no steer, no
/// interrupt, no socket. What it does have is documented auto-continuation: a
/// `stop` hook may answer `{"followup_message": "…"}` and Cursor submits that as
/// the next message. So a phone instruction for a *running* Cursor turn is held
/// here and collected by the hook at the moment the turn settles.
///
/// The queue holds at most one message per conversation: a second instruction
/// before the first is collected replaces it, because two queued messages would
/// arrive as one surprise continuation each. Entries expire so a message queued
/// against a turn that never ends (Cursor quit, hook uninstalled) cannot surface
/// hours later against a conversation the person has moved on from.
public actor CursorFollowupQueue {
    public struct Entry: Equatable, Sendable {
        public let text: String
        public let queuedAt: Date
        public let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let lifetime: TimeInterval

    /// 30 minutes: long enough for a real Cursor turn (the longest observed
    /// local turns run tens of minutes), short enough that a forgotten message
    /// does not reappear in a later session.
    public init(lifetime: TimeInterval = 30 * 60) {
        self.lifetime = lifetime
    }

    /// Queue (or replace) the follow-up for one conversation. Returns the entry
    /// that is now waiting.
    @discardableResult
    public func queue(conversationID: String, text: String, now: Date = Date()) -> Entry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !conversationID.isEmpty, !trimmed.isEmpty else { return nil }
        let entry = Entry(text: trimmed, queuedAt: now, expiresAt: now.addingTimeInterval(lifetime))
        entries[conversationID] = entry
        return entry
    }

    /// What is waiting for this conversation, without consuming it — for the
    /// snapshot's receipt line. Expired entries are dropped here too.
    public func peek(conversationID: String, now: Date = Date()) -> Entry? {
        guard let entry = entries[conversationID] else { return nil }
        guard entry.expiresAt > now else {
            entries.removeValue(forKey: conversationID)
            return nil
        }
        return entry
    }

    /// Hand the follow-up to the `stop` hook. Collecting clears it: Cursor
    /// submits the message itself, so a second delivery would repeat it.
    public func take(conversationID: String, now: Date = Date()) -> String? {
        guard let entry = peek(conversationID: conversationID, now: now) else { return nil }
        entries.removeValue(forKey: conversationID)
        return entry.text
    }

    /// Drop a queued message the user no longer wants sent.
    public func cancel(conversationID: String) {
        entries.removeValue(forKey: conversationID)
    }

    public func purgeExpired(now: Date = Date()) {
        entries = entries.filter { $0.value.expiresAt > now }
    }
}
