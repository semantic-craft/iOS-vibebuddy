import SwiftUI
import VibeBuddyKit

struct PhoneQuestionDraft: Equatable {
    var picked: [String: Set<String>] = [:]
    var typed: [String: String] = [:]
    var isEmpty: Bool { picked.values.allSatisfy(\.isEmpty) && typed.values.allSatisfy(\.isEmpty) }
}

@MainActor
final class PhoneReaderDrafts: ObservableObject {
    struct Draft: Equatable {
        let target: AgentSession
        var text = ""
        var question = PhoneQuestionDraft()
        var isEmpty: Bool { text.isEmpty && question.isEmpty }

        func matches(_ current: AgentSession) -> Bool {
            target.id == current.id && target.status == current.status
                && target.statusSince == current.statusSince
                && target.completionID == current.completionID
                && target.pendingQuestion?.id == current.pendingQuestion?.id
                && target.pendingApproval?.id == current.pendingApproval?.id
        }
    }

    private struct Key: Hashable { let scope: String; let session: String }
    @Published private var values: [Key: Draft] = [:]

    func draft(scope: String, session: AgentSession) -> Draft {
        values[Key(scope: scope, session: session.id)] ?? Draft(target: session)
    }

    func update(scope: String, session: AgentSession, _ change: (inout Draft) -> Void) {
        var value = draft(scope: scope, session: session)
        guard value.matches(session) else { return }
        change(&value)
        values[Key(scope: scope, session: session.id)] = value.isEmpty ? nil : value
    }

    func discard(scope: String, session: AgentSession) {
        values[Key(scope: scope, session: session.id)] = nil
    }

    func clearIfUnchanged(_ sent: Draft, scope: String, session: AgentSession) {
        let key = Key(scope: scope, session: session.id)
        guard values[key] == sent else { return }
        values[key] = nil
    }
}
