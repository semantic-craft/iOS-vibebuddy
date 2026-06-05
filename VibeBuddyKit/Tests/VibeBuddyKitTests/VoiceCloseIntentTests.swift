import Testing
@testable import VibeBuddyKit

@Suite("VoiceCloseIntent — end the call hands-free")
struct VoiceCloseIntentTests {

    @Test("bare farewells close the call")
    func bareFarewells() {
        #expect(VoiceCloseIntent.shouldClose("再见"))
        #expect(VoiceCloseIntent.shouldClose("拜拜"))
        #expect(VoiceCloseIntent.shouldClose("bye"))
        #expect(VoiceCloseIntent.shouldClose("goodbye"))
    }

    @Test("a farewell inside a short reply still closes (punctuation ignored)")
    func farewellInPhrase() {
        #expect(VoiceCloseIntent.shouldClose("好的，再见！"))
        #expect(VoiceCloseIntent.shouldClose("拜拜啦"))
        #expect(VoiceCloseIntent.shouldClose("ok bye!"))
    }

    @Test("bare close commands close the call")
    func bareCommands() {
        #expect(VoiceCloseIntent.shouldClose("关闭"))
        #expect(VoiceCloseIntent.shouldClose("结束对话"))
        #expect(VoiceCloseIntent.shouldClose("退出"))
        #expect(VoiceCloseIntent.shouldClose("stop"))
    }

    @Test("commands embedded in a real sentence do NOT close (avoid false triggers)")
    func embeddedCommandsIgnored() {
        #expect(!VoiceCloseIntent.shouldClose("帮我关闭那个文件"))
        #expect(!VoiceCloseIntent.shouldClose("stop editing main.swift"))
        #expect(!VoiceCloseIntent.shouldClose("结束这个会话之前先跑测试"))
    }

    @Test("ordinary speech and empty input never close")
    func ordinary() {
        #expect(!VoiceCloseIntent.shouldClose("我们继续吧"))
        #expect(!VoiceCloseIntent.shouldClose("what's the status"))
        #expect(!VoiceCloseIntent.shouldClose(""))
        #expect(!VoiceCloseIntent.shouldClose("   "))
    }
}
