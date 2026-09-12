import Testing
@testable import VibeBuddyKit

@Suite("VoiceCloseIntent — end the call hands-free")
struct VoiceCloseIntentTests {
    @Test func liveRequiresAnExplicitWholeCallCommand() {
        for text in ["请立即挂断这次语音通话", "结束通话", "Please end this call."] {
            #expect(VoiceCloseIntent.isExplicitCallEnd(text))
        }
        for text in ["再见", "再见是什么意思", "不要挂断通话", "你刚才说挂断通话", "挂断编程任务", "“挂断通话”", "「结束通话」", "《结束通话》", "挂断通话？"] {
            #expect(!VoiceCloseIntent.isExplicitCallEnd(text))
        }
    }

    @Test("farewells, negation, quoted speech, questions and task endings stay open")
    func nonCommands() {
        for text in ["不要说再见", "请解释‘拜拜’的意思", "goodbye是什么意思", "done", "关闭？", "再见", "ok bye!", "stop editing main.swift", ""] {
            #expect(!VoiceCloseIntent.isExplicitCallEnd(text))
        }
    }
}
