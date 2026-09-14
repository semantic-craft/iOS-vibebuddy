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

    @Test("builds quota links for one provider or all of them")
    func buildsQuotaURL() {
        #expect(VibeBuddyDeepLink.quotaURL(.claude).absoluteString == "vibebuddy://quota/claude")
        #expect(VibeBuddyDeepLink.quotaURL(nil).absoluteString == "vibebuddy://quota/all")
        #expect(VibeBuddyDeepLink.quotaProvider(from: VibeBuddyDeepLink.quotaURL(.grokBot)) == .some(.grokBot))
    }

    @Test("all, the Watch's both, and unknown segments open the page head")
    func quotaAllLandsOnTop() {
        for raw in ["all", "both", "someday"] {
            #expect(VibeBuddyDeepLink.quotaProvider(from: URL(string: "vibebuddy://quota/\(raw)")!) == .some(nil))
        }
    }

    @Test("a session or foreign link is not a quota link")
    func rejectsNonQuotaURLs() {
        #expect(VibeBuddyDeepLink.quotaProvider(from: VibeBuddyDeepLink.sessionURL(id: "abc")) == nil)
        #expect(VibeBuddyDeepLink.quotaProvider(from: URL(string: "https://example.com/quota/claude")!) == nil)
    }

    @Test("rejects unrelated URLs")
    func rejectsForeignURLs() {
        #expect(VibeBuddyDeepLink.sessionId(from: URL(string: "https://example.com/session/x")!) == nil)
        #expect(VibeBuddyDeepLink.sessionId(from: URL(string: "vibebuddy://other/x")!) == nil)
        #expect(VibeBuddyDeepLink.sessionId(from: URL(string: "vibebuddy://session/")!) == nil)
    }
}
