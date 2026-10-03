import Foundation
import VibeBuddyKit

public struct AntigravityDesktopObservation: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case working
        case waiting(WaitKind, String?)
        case succeeded
        case cancelled
        case failed
        case unknown
    }
    public let conversation: AntigravityDesktopConversation
    public let state: State
    public let finalText: String?
}

/// Only state and user-facing fields are decoded. Configuration, credentials and
/// model prompts in the native response are neither stored nor logged.
public struct AntigravityDesktopSteps: Decodable, Sendable {
    let steps: [Step]
    struct Step: Decodable, Sendable {
        let type: String?
        let status: String?
        let requestedInteraction: Interaction?
        let askQuestion: QuestionSet?
        let plannerResponse: Planner?
        struct Planner: Decodable, Sendable {
            let response: String?
            let toolCalls: [Tool]?
            struct Tool: Decodable, Sendable { let name: String? }
        }
        struct Interaction: Decodable, Sendable {
            let askQuestion: QuestionSet?
            // Native 2.19.1 RequestedInteraction oneof fields 3, 21 and 23.
            // Their response messages carry confirm/allow, unlike askQuestion.
            let runCommand: Confirmation?
            let permission: Permission?
            let approvalInteraction: Confirmation?
            struct Confirmation: Decodable, Sendable {}
            struct Permission: Decodable, Sendable {
                let reason: String?
                let actionDescription: String?
            }
        }
        struct QuestionSet: Decodable, Sendable {
            let questions: [Question]?
            struct Question: Decodable, Sendable { let question: String? }
        }
    }

    public func observation(for conversation: AntigravityDesktopConversation) -> AntigravityDesktopObservation {
        let start = steps.lastIndex(where: { $0.type == "CORTEX_STEP_TYPE_USER_INPUT" }) ?? steps.startIndex
        let current = steps[start...]
        let last = current.last
        let state: AntigravityDesktopObservation.State
        // Cancellation keeps requestedInteraction in the response. Status wins;
        // retaining the payload must never retain a question card.
        if conversation.status.hasSuffix("IDLE"),
           ["CORTEX_STEP_STATUS_CANCELED", "CORTEX_STEP_STATUS_CANCELLED"].contains(last?.status ?? "") {
            state = .cancelled
        } else if let waiting = current.last(where: { $0.status == "CORTEX_STEP_STATUS_WAITING" && ($0.requestedInteraction != nil || $0.askQuestion != nil) }) {
            let interaction = waiting.requestedInteraction
            if let questions = interaction?.askQuestion ?? waiting.askQuestion {
                let text = questions.questions?.compactMap(\.question).joined(separator: "\n")
                state = .waiting(.question, text?.isEmpty == false ? text : "Waiting for a response in Antigravity")
            } else if interaction?.runCommand != nil || interaction?.permission != nil || interaction?.approvalInteraction != nil {
                let details = [interaction?.permission?.actionDescription, interaction?.permission?.reason]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    .joined(separator: "\n")
                state = .waiting(.permission, details.isEmpty ? "Approval requested in Antigravity" : details)
            } else {
                // Decodable ignores unknown oneof fields; an opaque interaction
                // is not evidence that the user was asked a question.
                state = .unknown
            }
        } else if conversation.status.hasSuffix("RUNNING") {
            state = .working
        } else if conversation.status.hasSuffix("IDLE"), last?.status == "CORTEX_STEP_STATUS_ERROR",
                  ["CORTEX_STEP_TYPE_PLANNER_RESPONSE", "CORTEX_STEP_TYPE_ERROR"].contains(last?.type ?? "") {
            state = .failed
        } else if conversation.status.hasSuffix("IDLE"), last?.type == "CORTEX_STEP_TYPE_PLANNER_RESPONSE",
                  last?.status == "CORTEX_STEP_STATUS_DONE", last?.plannerResponse?.toolCalls?.isEmpty != false {
            state = .succeeded
        } else {
            // A DONE tool or an unrecognized terminal shape is not success.
            state = .unknown
        }
        return AntigravityDesktopObservation(conversation: conversation, state: state,
            finalText: state == .succeeded ? last?.plannerResponse?.response : nil)
    }
}
