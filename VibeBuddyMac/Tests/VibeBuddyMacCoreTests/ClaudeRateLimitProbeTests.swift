import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Claude rate-limit probe")
struct ClaudeRateLimitProbeTests {
    @Test("a rate_limit_event (CLI 2.1.281) becomes the five-hour and seven-day windows")
    func decodesUnifiedWindows() throws {
        let output = """
        {"type":"system","subtype":"init","session_id":"s"}
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1790500800,"rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.01,"resetsAt":1790500800},"seven_day":{"utilization":0.24,"resetsAt":1791028800}}},"session_id":"s"}
        {"type":"result","subtype":"success","is_error":false,"result":"."}
        """
        let snapshot = try ClaudeRateLimitEventDecoder.decode(streamJSON: output, fetchedAt: Date())
        #expect(snapshot.provider == .claude)
        #expect(snapshot.primary?.usedPercent == 1)
        #expect(snapshot.primary?.windowDurationMinutes == 300)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1790500800))
        #expect(snapshot.secondary?.usedPercent == 24)
        #expect(snapshot.secondary?.windowDurationMinutes == 10080)
    }

    @Test("a 401 with no event is signed out, not a format error")
    func authFailureIsSignedOut() {
        let output = """
        {"type":"system","subtype":"api_retry","attempt":1,"error_status":401,"error":"authentication_failed"}
        {"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error"}
        """
        #expect(throws: AccountUsageError.notLoggedIn) {
            try ClaudeRateLimitEventDecoder.decode(streamJSON: output, fetchedAt: Date())
        }
    }

    @Test("the probe's environment names the login account and drops agent switches")
    func environment() {
        let env = ClaudeRateLimitProbe.environment(
            for: URL(fileURLWithPath: "/usr/local/bin/claude"),
            from: ["HOME": "/Users/a", "PATH": "/usr/bin", "ANTHROPIC_API_KEY": "k", "CLAUDE_CODE_ENTRYPOINT": "cli"],
            home: URL(fileURLWithPath: "/Users/a"))
        #expect(env["USER"]?.isEmpty == false)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["CLAUDE_CODE_ENTRYPOINT"] == nil)
    }
}
