import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("VibeBuddyDeepLink")
struct DeepLinkTests {

    @Test("builds a vibebuddy://session/<id> URL")
    func buildsSessionURL() {
        let url = VibeBuddyDeepLink.sessionURL(id: "abc123")
        #expect(url.scheme == VibeBuddyDeepLink.scheme)
        #expect(url.absoluteString == "vibebuddy://session?id=abc123")
    }

    @Test("parses the session id back out")
    func parsesSessionId() {
        let url = VibeBuddyDeepLink.sessionURL(id: "demo-edit")
        #expect(VibeBuddyDeepLink.sessionId(from: url) == "demo-edit")
    }

    @Test("round-trips ids that need percent-encoding")
    func roundTripsEncodedId() {
        let id = "proj/main#1"
        let url = VibeBuddyDeepLink.sessionURL(id: id)
        #expect(VibeBuddyDeepLink.sessionId(from: url) == id)
    }

    @Test("rejects unrelated URLs")
    func rejectsForeignURLs() {
        #expect(VibeBuddyDeepLink.sessionId(from: URL(string: "https://example.com/session/x")!) == nil)
        #expect(VibeBuddyDeepLink.sessionId(from: URL(string: "vibebuddy://other/x")!) == nil)
        #expect(VibeBuddyDeepLink.sessionId(from: URL(string: "vibebuddy://session/")!) == nil)
    }
}
