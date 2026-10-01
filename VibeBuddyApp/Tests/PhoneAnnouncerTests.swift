import XCTest
import AVFoundation
import VibeBuddyKit
@testable import VibeBuddyApp

/// The phone's read-aloud plan (ticket 04): the pending queue in order, each
/// item bound to its round, so a change between planning and speaking skips
/// the item instead of announcing stale news. No audio is exercised here.
final class PhoneAnnouncerTests: XCTestCase {
    private let now = Date()

    private func session(_ id: String, _ status: SessionStatus, minutesAgo: Double = 1,
                         unread: Bool = false, completion: String? = nil, failed: Bool = false,
                         approval: String? = nil, question: String? = nil) -> AgentSession {
        let at = now.addingTimeInterval(-minutesAgo * 60)
        var s = AgentSession(id: id, agent: .codex, project: id, status: status,
                             hasUnreadCompletion: unread, statusSince: at, updatedAt: at)
        s.completionID = completion
        if failed { s.failed = true }
        if let approval {
            s.waitKind = .permission
            s.pendingApproval = PendingApproval(id: approval, tool: "Bash", commandPreview: "swift test")
        }
        if let question {
            s.waitKind = .question
            s.pendingQuestion = PendingQuestion(id: question, prompt: "Which?")
        }
        return s
    }

    func testPlanFollowsThePendingQueueAndNamesEachRound() {
        let sessions = [session("result", .done, unread: true, completion: "c1"),
                        session("stuck", .done, failed: true),
                        session("ask", .needsResponse, question: "q1"),
                        session("run", .working),
                        session("approve", .needsResponse, approval: "a1")]
        let plan = AnnouncementPlan(pending: PendingTasks.ordered(sessions))
        XCTAssertEqual(plan.items.map(\.sessionID), ["ask", "approve", "stuck", "result"],
                       "questions, then approvals, then failures, then unread results — the shared order")
        XCTAssertEqual(plan.items.map(\.sound), [.needsAnswer, .needsApproval, .agentStuck, .agentDone])
        XCTAssertEqual(plan.items.last?.round, "c1")
        XCTAssertEqual(plan.overflow, 0)
    }

    func testAnItemIsSkippedOnceItsRoundMovedOn() {
        let result = session("result", .done, unread: true, completion: "c1")
        let approve = session("approve", .needsResponse, approval: "a1")
        let plan = AnnouncementPlan(pending: PendingTasks.ordered([result, approve]))
        let resultItem = plan.items.first { $0.sessionID == "result" }!
        let approveItem = plan.items.first { $0.sessionID == "approve" }!

        XCTAssertNotNil(AnnouncementPlan.stillCurrent(resultItem, in: [result, approve]))
        // Read on another device: not news any more.
        var read = result; read.hasUnreadCompletion = false
        XCTAssertNil(AnnouncementPlan.stillCurrent(resultItem, in: [read, approve]))
        // A newer round: the old text would be wrong.
        var next = result; next.completionID = "c2"
        XCTAssertNil(AnnouncementPlan.stillCurrent(resultItem, in: [next, approve]))
        // The approval was answered and the agent carried on.
        let running = session("approve", .working)
        XCTAssertNil(AnnouncementPlan.stillCurrent(approveItem, in: [result, running]))
        // Gone from the snapshot entirely.
        XCTAssertNil(AnnouncementPlan.stillCurrent(approveItem, in: [result]))
    }
}

private struct SilentPhoneSynthesizer: SpeechSynthesizer {
    let data: Data
    func synthesize(_ text: String, apiKey: String) async throws -> Data { data }
}

@MainActor
final class PhoneAnnouncerPlaybackTests: XCTestCase {
    private func silence() -> Data {
        let samples = 16_000
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + samples * 2))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000))
        append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }

    private func player(_ announcer: PhoneAnnouncer) -> AVAudioPlayer? {
        guard let value = Mirror(reflecting: announcer).children.first(where: { $0.label == "player" })?.value else { return nil }
        return Mirror(reflecting: value).children.first?.value as? AVAudioPlayer
    }

    private func startedReader() async throws -> (PhoneAnnouncer, AVAudioPlayer) {
        let data = silence()
        let announcer = PhoneAnnouncer(providerKey: { _ in "synthetic-not-a-key" },
                                       makeSynthesizer: { _ in SilentPhoneSynthesizer(data: data) })
        announcer.preview()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while player(announcer)?.isPlaying != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let audio = try XCTUnwrap(player(announcer))
        XCTAssertTrue(audio.isPlaying)
        return (announcer, audio)
    }

    private func holdMainActorUntilAudioEnds() {
        Thread.sleep(forTimeInterval: 1.2)
    }

    func testResumeAfterNaturalCompletionDoesNotReplay() async throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain([PhoneReadAloudSelection.defaultsKey: "qwen"], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let (announcer, audio) = try await startedReader()
        defer { announcer.stop() }
        holdMainActorUntilAudioEnds()
        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(audio.currentTime, 0)
        announcer.pause()
        XCTAssertTrue(announcer.isPaused)
        announcer.resume()
        XCTAssertFalse(audio.isPlaying, "A completion awaiting the poll must not be replayed by Pause/Resume")
    }

    func testExplicitPauseResumesFromTheSamePosition() async throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain([PhoneReadAloudSelection.defaultsKey: "qwen"], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let (announcer, audio) = try await startedReader()
        defer { announcer.stop() }
        try await Task.sleep(for: .milliseconds(100))
        announcer.pause()
        let position = audio.currentTime
        XCTAssertGreaterThan(position, 0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(audio.currentTime, position, accuracy: 0.02)
        announcer.resume()
        XCTAssertTrue(audio.isPlaying)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(audio.currentTime, position)
    }

    func testInterruptionResumesAudioAlreadyPausedByTheSystem() async throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain([PhoneReadAloudSelection.defaultsKey: "qwen"], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let (announcer, audio) = try await startedReader()
        defer { announcer.stop() }
        try await Task.sleep(for: .milliseconds(120))
        audio.pause()
        let position = audio.currentTime
        XCTAssertGreaterThan(position, 0)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        for _ in 0..<100 where !announcer.isPaused { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(announcer.isPaused)
        announcer.resume()
        XCTAssertTrue(audio.isPlaying)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(audio.currentTime, position)
    }

    func testInterruptionAfterCompletionDoesNotReplay() async throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain([PhoneReadAloudSelection.defaultsKey: "qwen"], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let (announcer, audio) = try await startedReader()
        defer { announcer.stop() }
        holdMainActorUntilAudioEnds()
        XCTAssertFalse(audio.isPlaying)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        for _ in 0..<100 where !announcer.isPaused && announcer.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        announcer.resume()
        XCTAssertFalse(audio.isPlaying)
    }
}


final class PhoneReadAloudLanguageTests: XCTestCase {
    func testIndependentReadingLanguagePreservesLegacyAndStandardVoice() throws {
        let name = "phone-reading-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(VoiceLanguage.chinese.rawValue, forKey: VoiceSettings.conversationLanguageKey)
        XCTAssertEqual(PhoneReadAloudSelection.language(defaults: defaults), .chinese)
        defaults.set(VoiceLanguage.english.rawValue, forKey: PhoneReadAloudSelection.languageKey)
        XCTAssertEqual(PhoneReadAloudSelection.configuration(.minimax, defaults: defaults).language, .english)
        XCTAssertEqual(VoiceSettings.conversationLanguage(defaults: defaults), .chinese)
        defaults.set("my-standard-voice", forKey: VoiceSettings.readAloudVoiceKey(.minimax))
        defaults.set(VoiceStyle.coquettish.rawValue, forKey: VoiceSettings.readAloudStyleKey(.minimax))
        defaults.set(VoiceLanguage.chinese.rawValue, forKey: PhoneReadAloudSelection.languageKey)
        let styled = PhoneReadAloudSelection.configuration(.minimax, defaults: defaults)
        XCTAssertEqual(styled.effectiveVoice, "diadia_xuemei")
        defaults.set(VoiceStyle.standard.rawValue, forKey: VoiceSettings.readAloudStyleKey(.minimax))
        XCTAssertEqual(PhoneReadAloudSelection.configuration(.minimax, defaults: defaults).effectiveVoice, "my-standard-voice")
    }
}

private struct FailingPhoneSynthesizer: SpeechSynthesizer {
    func synthesize(_ text: String, apiKey: String) async throws -> Data { throw SpeechSynthesisFailure.quotaExceeded }
}

@MainActor
final class PhoneSpeechRecoveryTests: XCTestCase {
    func testSkipPreservesManualCallAndFailurePausesUntilExplicitResume() async throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain([PhoneReadAloudSelection.defaultsKey: "minimax"], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        for reason in ["manual", "voice-call", "provider-failure"] {
            let announcer = PhoneAnnouncer(providerKey: { _ in "synthetic-not-a-key" }, makeSynthesizer: { _ in FailingPhoneSynthesizer() })
            let sessions = ["first", "second"].map { id -> AgentSession in
                var session = AgentSession(id: id, agent: .codex, project: "test", status: .done,
                                           hasUnreadCompletion: true, statusSince: Date(), updatedAt: Date())
                session.completionID = "round-1"
                return session
            }
            let source = UUID()
            var prepared = 0
            announcer.announce(sessions, live: { sessions }, source: { source }, content: { item in
                prepared += 1
                if reason != "provider-failure" { try await Task.sleep(for: .seconds(60)) }
                return DashboardStore.Announcement(text: "Verified result", context: .init(source: "mac", epoch: "1", generation: source, revision: nil), target: .completion(sessionID: item.sessionID, completionID: item.round), savedFallback: false, savedCompletionNotice: nil)
            }, validate: { _ in true })
            for _ in 0..<100 where prepared == 0 || (reason == "provider-failure" && !announcer.canUseSystemSpeech) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(prepared, 1, reason)
            if reason == "voice-call" { announcer.voiceStarted(); announcer.voiceEnded() }
            else if reason == "manual" { announcer.pause() }
            XCTAssertTrue(announcer.isPaused, reason)
            announcer.skip()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(announcer.isPaused, reason)
            XCTAssertEqual(prepared, 1, "Skip must not prepare the next paid item: " + reason)
            announcer.resume()
            for _ in 0..<100 where prepared < 2 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(prepared, 2, reason)
            announcer.stop()
        }
    }

    func testNewCompletionInvalidatesPreparedRecovery() async throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain([PhoneReadAloudSelection.defaultsKey: "minimax"], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let announcer = PhoneAnnouncer(providerKey: { _ in "synthetic-not-a-key" }, makeSynthesizer: { _ in FailingPhoneSynthesizer() })
        var session = AgentSession(id: "codex:test", agent: .codex, project: "test", status: .done, hasUnreadCompletion: true, statusSince: Date(), updatedAt: Date())
        session.completionID = "round-1"
        let source = UUID()
        let announcement = DashboardStore.Announcement(text: "Verified result", context: .init(source: "mac", epoch: "1", generation: source, revision: nil), target: .completion(sessionID: session.id, completionID: "round-1"), savedFallback: false, savedCompletionNotice: nil)
        announcer.announce([session], live: { [session] in [session] }, source: { source }, content: { _ in announcement }, validate: { _ in session.completionID == "round-1" })
        for _ in 0..<100 where !announcer.canUseSystemSpeech { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(announcer.canUseSystemSpeech)
        session.completionID = "round-2"
        announcer.useSystemSpeech()
        XCTAssertFalse(announcer.canUseSystemSpeech)
        XCTAssertFalse(announcer.isBusy)
        XCTAssertEqual(announcer.spokenCount, 0)
        announcer.stop()
    }

    func testSourceChangeRevokesRecoveryBeforeSystemPlayback() async throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain([PhoneReadAloudSelection.defaultsKey: "minimax"], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let announcer = PhoneAnnouncer(providerKey: { _ in "synthetic-not-a-key" }, makeSynthesizer: { _ in FailingPhoneSynthesizer() })
        // Preview has no task round, but cancellation still revokes its recovery.
        announcer.preview()
        for _ in 0..<100 where !announcer.canUseSystemSpeech { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(announcer.canUseSystemSpeech)
        announcer.sourceChanged()
        announcer.useSystemSpeech()
        XCTAssertFalse(announcer.isBusy)
        XCTAssertFalse(announcer.canUseSystemSpeech)
        XCTAssertEqual(announcer.spokenCount, 0)
    }

    func testFailureWaitsForExplicitRecoveryAndStopClearsIt() async throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain([PhoneReadAloudSelection.defaultsKey: "minimax"], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let announcer = PhoneAnnouncer(providerKey: { _ in "synthetic-not-a-key" }, makeSynthesizer: { _ in FailingPhoneSynthesizer() })
        announcer.preview()
        for _ in 0..<100 where !announcer.canUseSystemSpeech { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(announcer.canUseSystemSpeech)
        XCTAssertTrue(announcer.isPaused)
        XCTAssertEqual(PhoneReadAloudSelection.load(), .provider(.minimax))
        announcer.resume()
        XCTAssertTrue(announcer.isPaused, "Resume must not retry a paid request")
        announcer.cancelPreview()
        XCTAssertFalse(announcer.canUseSystemSpeech)
        XCTAssertFalse(announcer.isBusy)
    }
}
