import Testing
@testable import VibeBuddyKit

@Suite("VoiceCloseIntent — end the call hands-free")
struct VoiceCloseIntentTests {
    @Test func liveRequiresAnExplicitWholeCallCommand() {
        for text in ["请立即挂断这次语音通话", "结束通话", "Please end this call."] {
            #expect(VoiceCloseIntent.isExplicitCallEnd(text))
        }
        for text in ["再见", "再见是什么意思", "不要挂断通话", "你刚才说挂断通话", "挂断编程任务", "“挂断通话”", "挂断通话？"] {
            #expect(!VoiceCloseIntent.isExplicitCallEnd(text))
        }
    }

}
