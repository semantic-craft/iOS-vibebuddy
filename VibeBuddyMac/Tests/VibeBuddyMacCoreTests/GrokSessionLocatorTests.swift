import Testing
import Foundation
@testable import VibeBuddyMacCore

/// A synthetic `~/.grok` tree. Shapes mirror the real store; every string is
/// invented so no private prose from a real session reaches the repo.
struct GrokFixture {
    /// Grok's own data directory (`$GROK_HOME`, else `~/.grok`), which is what
    /// the locator and `SessionStore` are rooted at.
    let home: URL
    let cwd: String
    let sessionID: String
    let directory: URL

    init(
        cwd: String = "/Users/fixture/Projects/demo app",
        sessionID: String = "01a00000-0000-7000-8000-000000000001",
        directoryName: String? = nil
    ) throws {
        self.home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-grok-\(UUID().uuidString)", isDirectory: true)
        self.cwd = cwd
        self.sessionID = sessionID
        let parent = directoryName ?? GrokSessionLocator.encode(cwd: cwd)!
        self.directory = GrokSessionLocator.sessionsRoot(grokHome: home)
            .appendingPathComponent(parent, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ contents: String) throws {
        try contents.write(to: directory.appendingPathComponent(name),
                           atomically: true, encoding: .utf8)
    }

    func writeSubagentMeta(id: String, _ contents: String) throws {
        let dir = directory.appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try contents.write(to: dir.appendingPathComponent("meta.json"),
                           atomically: true, encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }

    // MARK: - Record builders

    static func summary(id: String = "01a00000-0000-7000-8000-000000000001",
                        cwd: String = "/Users/fixture/Projects/demo app") -> String {
        """
        {"info":{"id":"\(id)","cwd":"\(cwd)"},"session_summary":"Fixture session",\
        "generated_title":"Fixture title","current_model_id":"grok-4.6",\
        "git_root_dir":"\(cwd)","head_branch":"feature/fixture","head_commit":"abc123",\
        "last_turn_summary":"stored turn recap","agent_name":"grok-build-plan",\
        "num_messages":12,"num_chat_messages":4}
        """
    }

    static let signals = """
        {"turnCount":2,"toolCallCount":5,"toolsUsed":["read_file"],"modelsUsed":["grok-4.6"],\
        "primaryModelId":"grok-4.6","compactionCount":0,"contextTokensUsed":80944,\
        "contextWindowTokens":500000,"contextWindowUsage":16,"errorCount":0}
        """

    /// One `updates.jsonl` line. `_meta` is a sibling of `update` inside `params`.
    static func update(_ inner: String, meta: String? = nil,
                       method: String = "session/update") -> String {
        let metaPart = meta.map { ",\"_meta\":\($0)" } ?? ""
        return """
            {"timestamp":1788354885,"method":"\(method)","params":\
            {"sessionId":"s","update":\(inner)\(metaPart)}}
            """
    }

    static func userChunk(_ text: String) -> String {
        update(#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"\#(text)"}}"#)
    }

    static func agentChunk(_ text: String, totalTokens: Int? = nil) -> String {
        update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(text)"}}"#,
               meta: totalTokens.map { #"{"totalTokens":\#($0)}"# })
    }

    static func thoughtChunk(_ text: String) -> String {
        update(#"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"\#(text)"}}"#)
    }

    static func toolCall(id: String, title: String) -> String {
        update(#"{"sessionUpdate":"tool_call","toolCallId":"\#(id)","title":"\#(title)","rawInput":{}}"#)
    }

    static func toolDone(id: String, status: String = "completed") -> String {
        update(#"{"sessionUpdate":"tool_call_update","toolCallId":"\#(id)","status":"\#(status)","rawOutput":{}}"#)
    }

    /// The `tool_call_update` variant that carries no `status` (a mid-flight
    /// content append), which must not close an open call.
    static func toolProgress(id: String) -> String {
        update(#"{"sessionUpdate":"tool_call_update","toolCallId":"\#(id)","kind":"execute","locations":[],"rawInput":{}}"#)
    }

    /// `promptID: nil` writes the record without a `prompt_id`, leaving `_meta`
    /// as the only turn identity — the shape the reader has to fall back to.
    static func turnCompleted(input: Int, output: Int, promptID: String? = "p1",
                              eventID: String? = nil) -> String {
        let prompt = promptID.map { #""prompt_id":"\#($0)","# } ?? ""
        return update("""
            {"sessionUpdate":"turn_completed",\(prompt)"stop_reason":"end_turn",\
            "usage":{"inputTokens":\(input),"outputTokens":\(output),\
            "totalTokens":\(input + output),"cachedReadTokens":0,"numTurns":1}}
            """, meta: eventID.map { #"{"eventId":"\#($0)"}"# }, method: "_x.ai/session/update")
    }

    static func subagentSpawned(id: String, type: String, detail: String) -> String {
        update("""
            {"sessionUpdate":"subagent_spawned","subagent_id":"\(id)",\
            "parent_session_id":"s","child_session_id":"\(id)",\
            "subagent_type":"\(type)","description":"\(detail)","model":"grok-4.6"}
            """)
    }

    static func subagentFinished(id: String) -> String {
        update("""
            {"sessionUpdate":"subagent_finished","subagent_id":"\(id)",\
            "child_session_id":"\(id)","status":"completed","tool_calls":3,"turns":1}
            """)
    }

    static func permissionRequested(_ tool: String) -> String {
        #"{"ts":"2026-09-02T13:14:51.807Z","type":"permission_requested","tool_name":"\#(tool)","schema_version":"1.0"}"#
    }

    static func permissionResolved(_ tool: String) -> String {
        #"{"ts":"2026-09-02T13:14:51.809Z","type":"permission_resolved","tool_name":"\#(tool)","decision":"allow","wait_ms":1}"#
    }
}

@Suite("Grok session locator")
struct GrokSessionLocatorTests {

    @Test("percent-encodes a cwd against the RFC 3986 unreserved set")
    func encodesCwd() {
        #expect(GrokSessionLocator.encode(cwd: "/Users/x/code/demo")
                == "%2FUsers%2Fx%2Fcode%2Fdemo")
        // `-`, `.`, `_` and `~` survive; a space does not.
        #expect(GrokSessionLocator.encode(cwd: "/a-b/c.d/e_f/~g h")
                == "%2Fa-b%2Fc.d%2Fe_f%2F~g%20h")
    }

    @Test("resolves the encoded-cwd path without scanning")
    func resolvesEncodedPath() throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }
        try fixture.write("summary.json", GrokFixture.summary())

        let found = GrokSessionLocator.locate(
            sessionID: fixture.sessionID, cwd: fixture.cwd, grokHome: fixture.home)
        #expect(found?.standardizedFileURL == fixture.directory.standardizedFileURL)
    }

    @Test("falls back to a scan for the slug-hash directory, and reads its .cwd")
    func resolvesSlugHashDirectory() throws {
        let fixture = try GrokFixture(directoryName: "demo-app-c871d1174b95948f")
        defer { fixture.cleanUp() }
        try fixture.write("summary.json", GrokFixture.summary())

        // The encoded path does not exist, so only the scan can find it.
        let found = GrokSessionLocator.locate(
            sessionID: fixture.sessionID, cwd: fixture.cwd, grokHome: fixture.home)
        #expect(found?.standardizedFileURL == fixture.directory.standardizedFileURL)
    }

    @Test("resolves without a cwd at all")
    func resolvesWithoutCwd() throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }
        try fixture.write("updates.jsonl", GrokFixture.userChunk("hello"))

        let found = GrokSessionLocator.locate(
            sessionID: fixture.sessionID, cwd: nil, grokHome: fixture.home)
        #expect(found?.standardizedFileURL == fixture.directory.standardizedFileURL)
    }

    @Test("an unknown session and a traversal id resolve to nothing")
    func rejectsUnknownAndUnsafe() throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }
        try fixture.write("summary.json", GrokFixture.summary())

        #expect(GrokSessionLocator.locate(sessionID: "nope", cwd: fixture.cwd,
                                          grokHome: fixture.home) == nil)
        #expect(GrokSessionLocator.locate(sessionID: "../..", cwd: nil,
                                          grokHome: fixture.home) == nil)
        #expect(GrokSessionLocator.locate(sessionID: "", cwd: nil, grokHome: fixture.home) == nil)
    }

    @Test("a hook transcript path pointing at updates.jsonl yields its directory")
    func directoryFromTranscriptPath() throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }
        try fixture.write("updates.jsonl", GrokFixture.userChunk("hello"))

        let path = fixture.directory.appendingPathComponent("updates.jsonl").path
        #expect(GrokSessionLocator.directory(forTranscriptPath: path)?.standardizedFileURL
                == fixture.directory.standardizedFileURL)
        // The directory itself is accepted as-is.
        #expect(GrokSessionLocator.directory(forTranscriptPath: fixture.directory.path)?
            .standardizedFileURL == fixture.directory.standardizedFileURL)
        #expect(GrokSessionLocator.directory(forTranscriptPath: "/tmp/not-a-session/x.jsonl") == nil)
    }
}
