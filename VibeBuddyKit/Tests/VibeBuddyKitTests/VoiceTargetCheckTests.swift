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

    @Test("common and command words, and two Latin letters, name nothing")
    func commonWords() {
        let grape = waiting("grape"), login = waiting("fix-the-login"), auto = waiting("auto-approve"), it = waiting("it")
        let scope = [grape, login, auto, it]
        #expect(VoiceTargetCheck.verdict(target: login, heard: "approve the grape request", scope: scope) == .namedOther("grape"))
        #expect(VoiceTargetCheck.verdict(target: auto, heard: "approve grape", scope: scope) == .namedOther("grape"))
        #expect(VoiceTargetCheck.verdict(target: it, heard: "deny it", scope: scope) == .unnamed)
        #expect(VoiceTargetCheck.verdict(target: login, heard: "approve the login one", scope: scope) == .named)
    }

    /// Qwen: speech starts, the tool call follows, the transcript comes last.
    private func qwenCoordinator(_ scope: [AgentSession], sent: @escaping (VoiceAction) -> Void,
                                 results: @escaping (String) -> Void) -> VoiceCallCoordinator {
        VoiceCallCoordinator(audio: SilentAudio(), actionHandler: { sent($0); return "Sent." },
            sendToolResult: { _, _, result in results(result) },
            contextProvider: { scope }, transcriptGrace: .seconds(2))
    }

    @Test("a name from the previous utterance does not release this one's action")
    func previousUtteranceIsStale() async {
        var sent: [VoiceAction] = [], results: [String] = []
        let c = qwenCoordinator([waiting("orange"), waiting("grape")], sent: { sent.append($0) }, results: { results.append($0) })
        c.handle(.userTranscript(text: "grape 在等什么？", final: true))
        c.handle(.assistantTranscript(text: "grape 在等一个 Bash 批准。", final: true))
        c.handle(.speechStarted)
        c.handle(.toolCall(name: "deny_session", arguments: #"{"project":"grape"}"#, callID: "1"))
        for _ in 0..<50 { await Task.yield() }
        #expect(sent.isEmpty) // waiting for this utterance's transcript
        c.handle(.userTranscript(text: "拒绝 orange。", final: true))
        await waitFor { results.count == 1 }
        #expect(sent.isEmpty)
        #expect(results.first?.contains("named orange, not grape") == true)
        c.stop()
    }

    @Test("a transcript arriving during the wait releases the named action")
    func lateTranscriptReleases() async {
        var sent: [VoiceAction] = [], results: [String] = []
        let c = qwenCoordinator([waiting("orange"), waiting("grape")], sent: { sent.append($0) }, results: { results.append($0) })
        c.handle(.speechStarted)
        c.handle(.toolCall(name: "deny_session", arguments: #"{"project":"grape"}"#, callID: "1"))
        for _ in 0..<50 { await Task.yield() }
        #expect(sent.isEmpty)
        c.handle(.userTranscript(text: "拒绝 grape 的请求。", final: true))
        await waitFor { results.count == 1 }
        #expect(sent == [.deny(project: "grape")])
        c.stop()
    }

    @Test("a revised partial hypothesis no longer counts")
    func revisedPartial() async {
        var sent: [VoiceAction] = [], results: [String] = []
        let c = qwenCoordinator([waiting("orange"), waiting("grape")], sent: { sent.append($0) }, results: { results.append($0) })
        c.handle(.speechStarted)
        c.handle(.userTranscript(text: "拒绝 orange", final: false))
        c.handle(.userTranscript(text: "拒绝 grape", final: false))
        c.handle(.userTranscript(text: "拒绝 grape。", final: true))
        c.handle(.toolCall(name: "deny_session", arguments: #"{"project":"orange"}"#, callID: "1"))
        await waitFor { results.count == 1 }
        #expect(sent.isEmpty)
        c.stop()
    }

    @Test("stopping during the wait sends nothing")
    func stopDuringWait() async {
        var sent: [VoiceAction] = [], results: [String] = []
        let c = qwenCoordinator([waiting("orange")], sent: { sent.append($0) }, results: { results.append($0) })
        c.handle(.toolCall(name: "deny_session", arguments: #"{"project":"orange"}"#, callID: "1"))
        for _ in 0..<50 { await Task.yield() }
        c.stop()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(sent.isEmpty && results.isEmpty && c.heldNotice == nil)
    }

    @Test("Live's continuous audio does not split the user's caption")
    func liveContinuousAudio() async {
        var sent: [VoiceAction] = [], results: [String] = []
        let c = VoiceCallCoordinator(audio: SilentAudio(), actionHandler: { sent.append($0); return "Sent." },
            sendToolResult: { _, _, result in results.append(result) }, continuousPlayback: true,
            contextProvider: { [self.waiting("orange"), self.waiting("grape")] }, transcriptGrace: .milliseconds(200))
        for (i, text) in ["approve ", "grape ", "please"].enumerated() {
            c.handle(.audioDelta(Data(count: 4800)))
            c.handle(.transcriptFragment(.init(speaker: .user, text: text, startMilliseconds: i * 400, endMilliseconds: i * 400 + 300)))
        }
        c.handle(.toolCall(name: "approve_session", arguments: #"{"project":"grape"}"#, callID: "1"))
        await waitFor { results.count == 1 }
        #expect(sent == [.approve(project: "grape")])
        c.stop()
    }

    @Test("a held call beside a sent one does not hide the sent receipt")
    func parallelCallsKeepTheReceipt() async {
        var results: [String] = []
        let c = qwenCoordinator([waiting("grape"), waiting("lemon")], sent: { _ in }, results: { results.append($0) })
        c.handle(.userTranscript(text: "approve grape", final: true))
        c.handle(.toolCall(name: "deny_session", arguments: #"{"project":"lemon"}"#, callID: "held"))
        c.handle(.toolCall(name: "approve_session", arguments: #"{"project":"grape"}"#, callID: "sent"))
        await waitFor { results.count == 2 }
        #expect(results.first == "Sent.")
        #expect(results.last.map(VoiceTargetCheck.isHeldResult) == true)
        #expect(c.lastReply == "Sent.")
        #expect(c.heldNotice != nil)
        c.stop()
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

@MainActor
private final class SilentAudio: VoiceCallAudio {
    var isPlaybackPending = false
    func flushPlayback() -> [VoicePlaybackCheckpoint] { [] }
    func enqueue(_ pcm: Data, item: VoiceAudioItem?) {}
    func stop() {}
}
