import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Dispatch request and Cursor model list on the wire")
struct DispatchRequestTests {
    @Test("a Cursor request carries model, mode and worktree; a plain one omits them")
    func roundTrip() throws {
        let full = DispatchRequest(agent: .cursor, cwd: "/x/p", prompt: "fix it", name: "fix",
                                   model: "gpt-5", mode: "plan", worktree: true)
        let data = try JSONEncoder().encode(full)
        #expect(try JSONDecoder().decode(DispatchRequest.self, from: data) == full)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""model":"gpt-5""#))
        #expect(text.contains(#""mode":"plan""#))
        #expect(text.contains(#""worktree":true"#))

        let plain = DispatchRequest(agent: .codex, cwd: "/x/p", prompt: "list files")
        let plainText = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!plainText.contains("model"))
        #expect(!plainText.contains("mode"))
        #expect(!plainText.contains("worktree"))
    }

    @Test("a request from a phone that predates the fields decodes with them nil")
    func olderPayload() throws {
        let old = #"{"agent":"cursor","cwd":"/x/p","prompt":"fix it","name":"fix"}"#
        let decoded = try JSONDecoder().decode(DispatchRequest.self, from: Data(old.utf8))
        #expect(decoded == DispatchRequest(agent: .cursor, cwd: "/x/p", prompt: "fix it", name: "fix"))
        #expect(decoded.model == nil && decoded.mode == nil && decoded.worktree == nil)
    }

    @Test("a Continue with… request carries its continuation; a plain one omits it and an older payload decodes without it")
    func continuation() throws {
        let continuing = DispatchRequest(agent: .codex, cwd: "/x/p", prompt: "Read /m/.scratch/e/handoffs/h.md, then continue.",
                                         continuation: DispatchContinuation(sourceKey: "claude-code:src", handoffPath: "/m/.scratch/e/handoffs/h.md"))
        let data = try JSONEncoder().encode(continuing)
        #expect(try JSONDecoder().decode(DispatchRequest.self, from: data) == continuing)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""sourceKey":"claude-code:src""#))
        #expect(text.contains(#""handoffPath":""#))   // JSONEncoder escapes the slashes
        let plain = String(decoding: try JSONEncoder().encode(DispatchRequest(agent: .codex, cwd: "/x/p", prompt: "p")), as: UTF8.self)
        #expect(!plain.contains("continuation"))
        let older = #"{"agent":"codex","cwd":"/x/p","prompt":"p"}"#
        #expect(try JSONDecoder().decode(DispatchRequest.self, from: Data(older.utf8)).continuation == nil)
        // The handoff path is optional: a continuation from the history tools alone.
        let bare = DispatchContinuation(sourceKey: "claude-code:src")
        #expect(try JSONDecoder().decode(DispatchContinuation.self, from: JSONEncoder().encode(bare)) == bare)
    }

    @Test("the snapshot carries cursorModels only when the Mac has some")
    func snapshotModels() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let with = Snapshot(sessions: [], serverTime: now, dispatchAgents: [.cursor],
                            cursorModels: ["gpt-5", "sonnet-4.5"])
        let data = try JSONEncoder().encode(with)
        #expect(try JSONDecoder().decode(Snapshot.self, from: data) == with)
        #expect(String(decoding: data, as: UTF8.self).contains(#""cursorModels":["gpt-5","sonnet-4.5"]"#))

        let without = Snapshot(sessions: [], serverTime: now, dispatchAgents: [.cursor])
        let bare = String(decoding: try JSONEncoder().encode(without), as: UTF8.self)
        #expect(!bare.contains("cursorModels"))
        // A snapshot from a Mac that predates the field.
        let older = #"{"sessions":[],"serverTime":1780000000,"dispatchAgents":["cursor"]}"#
        let decoded = try JSONDecoder().decode(Snapshot.self, from: Data(older.utf8))
        #expect(decoded.cursorModels == nil)
        #expect(decoded.dispatchAgents == [.cursor])
    }
}
