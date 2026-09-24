import Foundation
import Testing
@testable import VibeBuddyKit

/// RV-03: a voice task action must not land on a waiting task the user did not name.
@Suite("VoiceTargetCheck — the user's words must name the action's target")
@MainActor
struct VoiceTargetCheckTests {
    private func waiting(_ project: String, name: String? = nil) -> AgentSession {
        var s = AgentSession(id: project, agent: .claudeCode, project: project, status: .needsResponse,
                             statusSince: Date(), updatedAt: Date())
        s.name = name
        s.waitKind = WaitKind.permission
        s.pendingApproval = PendingApproval(id: project + "-a", tool: "Bash", commandPreview: "touch x")
        return s
    }

    @Test("names, other names and nothing heard")
    func verdicts() {
        let orange = waiting("orange"), grape = waiting("grape"), lemon = waiting("lemon")
        let scope = [orange, grape, lemon]
        #expect(VoiceTargetCheck.verdict(target: orange, heard: "拒绝 grape 项目里等待的请求", scope: scope) == .namedOther("grape"))
        // The 2026-09-24 transcript: "grape" was heard as 高客.
        #expect(VoiceTargetCheck.verdict(target: orange, heard: "拒绝高客项目里存在的请求。", scope: scope) == .unnamed)
        #expect(VoiceTargetCheck.verdict(target: orange, heard: "", scope: scope) == .unnamed)
        #expect(VoiceTargetCheck.verdict(target: orange, heard: "Deny ORANGE, please", scope: scope) == .named)
        #expect(VoiceTargetCheck.verdict(target: waiting("桃子"), heard: "批准桃子的请求。", scope: [waiting("桃子"), waiting("李子")]) == .named)
    }

    @Test("spelling is forgiven, identity is not")
    func lenientButStrict() {
        let buddy = waiting("vibe-buddy"), ios = waiting("ios-vibebuddy"), mac = waiting("mac-vibebuddy")
        #expect(VoiceTargetCheck.verdict(target: buddy, heard: "approve vibe buddy", scope: [buddy]) == .named)
        // A distinct word counts; a word two tasks share does not.
        #expect(VoiceTargetCheck.verdict(target: ios, heard: "approve the iOS one", scope: [ios, mac]) == .named)
        #expect(VoiceTargetCheck.verdict(target: ios, heard: "approve vibebuddy", scope: [ios, mac]) == .unnamed)
        // A short name heard only inside a longer in-scope name is not named.
        let app = waiting("app"), server = waiting("app-server")
        #expect(VoiceTargetCheck.verdict(target: app, heard: "approve app-server", scope: [app, server]) == .namedOther("app-server"))
        #expect(VoiceTargetCheck.verdict(target: app, heard: "approve app", scope: [app, server]) == .named)
        // A session title names it too.
        let titled = waiting("repo", name: "Payments refactor")
        #expect(VoiceTargetCheck.verdict(target: titled, heard: "approve payments refactor", scope: [titled, grapeLike]) == .named)
    }

    private var grapeLike: AgentSession { waiting("grape") }

    @Test("grape→orange: deny for a waiting task the user did not name is held, never sent")
    func grapeToOrangeIsHeld() async {
        let scope = [waiting("orange"), waiting("grape"), waiting("lemon")]
        var sent: [VoiceAction] = []
        var results: [String] = []
        let coordinator = VoiceCallCoordinator(audio: SilentAudio(), actionHandler: { action in
            sent.append(action); return "Sent."
        }, sendToolResult: { _, _, result in results.append(result) },
           contextProvider: { scope }, transcriptGrace: .milliseconds(300))
        // Qwen order: the tool call first, the user's transcript ~0.2 s later.
        coordinator.handle(.toolCall(name: "deny_session", arguments: #"{"project":"orange"}"#, callID: "1"))
        coordinator.handle(.userTranscript(text: "拒绝 grape 项目里等待的请求。", final: true))
        await waitFor { results.count == 1 }
        #expect(sent.isEmpty)
        #expect(results[0].hasPrefix("Not sent: the user named grape, not orange"))
        #expect(coordinator.heldNotice == String(localized: "Not sent to orange: you said grape.", bundle: .module))

        // The model corrects itself: the named task goes through.
        coordinator.handle(.toolCall(name: "deny_session", arguments: #"{"project":"grape"}"#, callID: "2"))
        await waitFor { results.count == 2 }
        #expect(sent == [.deny(project: "grape")])
        #expect(coordinator.heldNotice == nil)
        coordinator.stop()
    }

    @Test("a garbled name holds the action until the user says the target's name")
    func confirmationBySayingTheName() async {
        let scope = [waiting("orange"), waiting("grape")]
        var sent: [VoiceAction] = []
        var results: [String] = []
        let coordinator = VoiceCallCoordinator(audio: SilentAudio(), actionHandler: { action in
            sent.append(action); return "Sent."
        }, sendToolResult: { _, _, result in results.append(result) },
           contextProvider: { scope }, transcriptGrace: .milliseconds(200))
        coordinator.handle(.userTranscript(text: "拒绝高客项目里存在的请求。", final: true))
        coordinator.handle(.toolCall(name: "deny_session", arguments: #"{"project":"orange"}"#, callID: "1"))
        await waitFor { results.count == 1 }
        #expect(sent.isEmpty)
        #expect(results[0].contains("did not name orange"))
        // The companion asks; an agreeing word alone does not name the task.
        coordinator.handle(.assistantTranscript(text: "你是说 orange 吗？请说出项目名。", final: true))
        coordinator.handle(.userTranscript(text: "对。", final: true))
        coordinator.handle(.toolCall(name: "deny_session", arguments: #"{"project":"orange"}"#, callID: "2"))
        await waitFor { results.count == 2 }
        #expect(sent.isEmpty)
        // Earlier words do not carry past the companion's reply; the name does.
        coordinator.handle(.assistantTranscript(text: "请说出项目名。", final: true))
        coordinator.handle(.userTranscript(text: "orange", final: true))
        coordinator.handle(.toolCall(name: "deny_session", arguments: #"{"project":"orange"}"#, callID: "3"))
        await waitFor { results.count == 3 }
        #expect(sent == [.deny(project: "orange")])
        coordinator.stop()
    }

    @Test("Live captions name the target; marking read is not held")
    func captionsAndMarkRead() async {
        let scope = [waiting("orange"), waiting("grape")]
        var sent: [VoiceAction] = []
        var results: [String] = []
        let coordinator = VoiceCallCoordinator(audio: SilentAudio(), actionHandler: { action in
            sent.append(action); return "Sent."
        }, sendToolResult: { _, _, result in results.append(result) }, continuousPlayback: true,
           contextProvider: { scope }, transcriptGrace: .milliseconds(200))
        coordinator.handle(.transcriptFragment(.init(speaker: .user, text: "approve ", startMilliseconds: 0, endMilliseconds: 300)))
        coordinator.handle(.transcriptFragment(.init(speaker: .user, text: "grape", startMilliseconds: 300, endMilliseconds: 600)))
        coordinator.handle(.toolCall(name: "approve_session", arguments: #"{"project":"grape"}"#, callID: "1"))
        coordinator.handle(.toolCall(name: "mark_read_session", arguments: #"{"project":"orange"}"#, callID: "2"))
        await waitFor { results.count == 2 }
        #expect(sent.contains(.approve(project: "grape")))
        #expect(sent.contains(.markRead(project: "orange")))
        coordinator.stop()
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

@MainActor
private final class SilentAudio: VoiceCallAudio {
    var isPlaybackPending = false
    func flushPlayback() -> [VoicePlaybackCheckpoint] { [] }
    func enqueue(_ pcm: Data, item: VoiceAudioItem?) {}
    func stop() {}
}
