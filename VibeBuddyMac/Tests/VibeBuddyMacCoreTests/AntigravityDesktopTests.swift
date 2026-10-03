import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

struct AntigravityDesktopTests {
    @Test func waitingStepOverridesRunningAndCancellationClearsIt() throws {
        let summary = AntigravityDesktopConversation(id: "native-id", title: "Probe", status: "RUNNING", stepCount: 3)
        let waiting = try JSONDecoder().decode(AntigravityDesktopSteps.self, from: Data(#"{"steps":[{"type":"CORTEX_STEP_TYPE_PLANNER_RESPONSE","status":"CORTEX_STEP_STATUS_DONE"},{"type":"CORTEX_STEP_TYPE_ASK_QUESTION","status":"CORTEX_STEP_STATUS_WAITING","requestedInteraction":{"askQuestion":{"questions":[{"question":"Choose Alpha or Beta"}]}}}]}"#.utf8))
        #expect(waiting.observation(for: summary).state == .waiting(.question, "Choose Alpha or Beta"))
        let cancelled = try JSONDecoder().decode(AntigravityDesktopSteps.self, from: Data(#"{"steps":[{"type":"CORTEX_STEP_TYPE_ASK_QUESTION","status":"CORTEX_STEP_STATUS_CANCELED","requestedInteraction":{"askQuestion":{"questions":[{"question":"Choose Alpha or Beta"}]}}}]}"#.utf8))
        #expect(cancelled.observation(for: summary).state == .working)
        let idle = AntigravityDesktopConversation(id: summary.id, title: summary.title, status: "IDLE", stepCount: 3)
        #expect(cancelled.observation(for: idle).state == .cancelled)
    }
    @Test func opaqueInteractionDoesNotBecomeAQuestion() throws {
        let summary = AntigravityDesktopConversation(id: "native-id", title: "Probe", status: "RUNNING", stepCount: 1)
        // Native 2.19.1's RunCommandInteractionSpec is an empty protobuf
        // message; its corresponding response has an explicit confirm bool.
        let command = try JSONDecoder().decode(AntigravityDesktopSteps.self, from: Data(#"{"steps":[{"type":"CORTEX_STEP_TYPE_RUN_COMMAND","status":"CORTEX_STEP_STATUS_WAITING","requestedInteraction":{"runCommand":{}}}]}"#.utf8))
        #expect(command.observation(for: summary).state == .waiting(.permission, "Approval requested in Antigravity"))
        let unknown = try JSONDecoder().decode(AntigravityDesktopSteps.self, from: Data(#"{"steps":[{"type":"CORTEX_STEP_TYPE_RUN_COMMAND","status":"CORTEX_STEP_STATUS_WAITING","requestedInteraction":{"futureInteraction":{}}}]}"#.utf8))
        #expect(unknown.observation(for: summary).state == .unknown)
    }
    @Test func historyIsQuietAndCancellationDoesNotBecomeSuccessfulCompletion() async {
        let monitor = AntigravityDesktopMonitor()
        let summary = AntigravityDesktopConversation(id: "native-id", title: "Probe", status: "IDLE", stepCount: 3, turnID: "turn-1")
        let history = AntigravityDesktopObservation(conversation: summary, state: .succeeded, finalText: "Old result")
        #expect(await monitor.events(for: history, now: Date()).isEmpty)
        let next = AntigravityDesktopConversation(id: "native-id", title: "Probe", status: "RUNNING", stepCount: 5, turnID: "turn-2")
        let waiting = AntigravityDesktopObservation(conversation: next, state: .waiting(.question, "Choose"), finalText: nil)
        #expect(await monitor.events(for: waiting, now: Date()).map(\.kind) == [.userPromptSubmit, .notification])
        let cancelled = AntigravityDesktopObservation(conversation: next, state: .cancelled, finalText: nil)
        let ending = await monitor.events(for: cancelled, now: Date())
        #expect(ending.count == 1)
        #expect(ending.first?.kind == .stop)
        #expect(ending.first?.userStopped == true)
        #expect(ending.first?.completionSucceeded == false)
        #expect(await monitor.events(for: cancelled, now: Date()).isEmpty)
    }
}
