import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// AI-04: a Claude `Stop` with background work still running must not ring
/// done. Payload shapes follow code.claude.com/docs/en/hooks#stop-input.
@Suite("Claude Stop with background work (AI-04)")
struct ClaudeBackgroundWorkTests {

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func parse(_ json: String, at offset: TimeInterval = 0) -> HookEvent? {
        HookParser.parse(Data(json.utf8), receivedAt: t0.addingTimeInterval(offset))
    }

    private func reduce(_ jsons: [(String, TimeInterval)]) -> SessionReducer {
        var reducer = SessionReducer()
        for (json, offset) in jsons {
            if let event = parse(json, at: offset) { reducer.apply(event) }
        }
        return reducer
    }

    private let start = #"{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"go"}"#

    private func stop(tasks: String? = nil, crons: String? = nil) -> String {
        var fields = [#""hook_event_name":"Stop""#, #""session_id":"s""#, #""last_assistant_message":"All set.""#]
        if let tasks { fields.append(#""background_tasks":"# + tasks) }
        if let crons { fields.append(#""session_crons":"# + crons) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    // MARK: Parsing

    @Test("the two arrays are counted by what they hold the turn for")
    func parsesArrays() throws {
        let event = try #require(parse(stop(
            tasks: #"[{"id":"a","type":"subagent","status":"running","description":"Explore"},"#
                + #"{"id":"b","type":"shell","status":"running","description":"npm test"},"#
                + #"{"id":"c","type":"workflow","description":"no status"},"#
                + #"{"id":"d","type":"monitor","status":"completed"}]"#,
            crons: #"[{"id":"loop","schedule":"*/1 * * * *","recurring":true,"prompt":"check"}]"#)))
        #expect(event.backgroundWork == BackgroundWork(holdingTasks: 2, otherTasks: 1, crons: 1))
    }

    @Test("no arrays means an older CLI, and a bad shape never costs the event")
    func missingOrMalformed() throws {
        #expect(try #require(parse(stop())).backgroundWork == nil)
        let odd = try #require(parse(#"{"hook_event_name":"Stop","session_id":"s","background_tasks":"soon"}"#))
        #expect(odd.kind == .stop)
        #expect(odd.backgroundWork == nil)
        let subagentStop = try #require(parse(#"{"hook_event_name":"Stop","session_id":"s","agent_id":"x","background_tasks":[]}"#))
        #expect(subagentStop.kind == .childLifecycle)
        #expect(subagentStop.backgroundWork == nil)
    }

    // MARK: Reducer rules

    @Test("rule 2: a running subagent holds the turn open and mints no completion")
    func subagentHolds() {
        let reducer = reduce([(start, 0), (stop(tasks: #"[{"id":"a","type":"subagent","status":"running"}]"#), 30)])
        let session = reducer.sessions["s"]
        #expect(session?.status == .working)
        #expect(session?.backgroundTaskCount == 1)
        #expect(session?.completionID == nil)
        #expect(reducer.heldStops["s"] != nil)
    }

    @Test("rule 3: shells and monitors outlive the turn, which completes normally")
    func shellCompletes() {
        let reducer = reduce([(start, 0), (stop(tasks: #"[{"id":"b","type":"shell","status":"running"}]"#, crons: "[]"), 30)])
        let session = reducer.sessions["s"]
        #expect(session?.status == .done)
        #expect(session?.hasUnreadCompletion == true)
        #expect(session?.completionID != nil)
        #expect(session?.backgroundTaskCount == 1)
        #expect(session?.loopScheduled == nil)
    }

    @Test("rule 4: a /loop round settles done without a result to announce")
    func loopSettlesQuietly() {
        let reducer = reduce([(start, 0), (stop(tasks: "[]", crons: #"[{"id":"loop","schedule":"*/1 * * * *"}]"#), 30)])
        let session = reducer.sessions["s"]
        #expect(session?.status == .done)
        #expect(session?.loopScheduled == true)
        #expect(session?.hasUnreadCompletion == false)
        #expect(session?.completionID == nil)
        // The next loop round starts a turn again and clears the mark.
        var next = reducer
        next.apply(parse(start, at: 90)!)
        #expect(next.sessions["s"]?.status == .working)
        #expect(next.sessions["s"]?.loopScheduled == nil)
    }

    @Test("rule 5: with empty arrays the subagent counter stands in, and its stop releases the turn")
    func counterFallbackAndRelease() throws {
        var reducer = reduce([
            (start, 0),
            (#"{"hook_event_name":"SubagentStart","session_id":"s","agent_id":"bg","agent_type":"Explore"}"#, 5),
            (stop(tasks: "[]", crons: "[]"), 30),
        ])
        #expect(reducer.sessions["s"]?.status == .working)
        let early = reducer.takeReleasableStop(sessionID: "s")
        #expect(early == nil)   // still running
        reducer.apply(parse(#"{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"bg","agent_type":"Explore"}"#, at: 200)!)
        let releasable = reducer.takeReleasableStop(sessionID: "s")
        let released = try #require(releasable)
        #expect(released.releasesHeldStop)
        reducer.apply(released)
        #expect(reducer.sessions["s"]?.status == .done)
        #expect(reducer.sessions["s"]?.hasUnreadCompletion == true)
        #expect(reducer.sessions["s"]?.backgroundTaskCount == nil)
        #expect(reducer.heldStops["s"] == nil)
    }

    @Test("task-list entries are not running work")
    func taskListDoesNotHold() {
        let reducer = reduce([
            (start, 0),
            (#"{"hook_event_name":"TaskCreated","session_id":"s","task_id":"t1","task_subject":"Write docs"}"#, 5),
            (stop(), 30),
        ])
        #expect(reducer.sessions["s"]?.status == .done)
        #expect(reducer.sessions["s"]?.completionID != nil)
    }

    @Test("a newer clean Stop replaces the held one, and a new turn discards it")
    func supersededHolds() {
        var reducer = reduce([(start, 0), (stop(tasks: #"[{"id":"a","type":"teammate","status":"running"}]"#), 30)])
        reducer.apply(parse(stop(tasks: "[]"), at: 120)!)
        #expect(reducer.sessions["s"]?.status == .done)
        #expect(reducer.heldStops["s"] == nil)

        var again = reduce([(start, 0), (stop(tasks: #"[{"id":"a","type":"workflow","status":"running"}]"#), 30)])
        again.apply(parse(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Read"}"#, at: 60)!)
        #expect(again.heldStops["s"] == nil)
        #expect(again.sessions["s"]?.backgroundTaskCount == nil)
    }

    @Test("backstop: a held Stop settles after ten minutes")
    func backstop() {
        var reducer = reduce([(start, 0), (stop(tasks: #"[{"id":"a","type":"workflow","status":"running"}]"#), 30)])
        let tooEarly = reducer.takeExpiredStops(now: t0.addingTimeInterval(30 + 599), after: 600)
        #expect(tooEarly.isEmpty)
        let expired = reducer.takeExpiredStops(now: t0.addingTimeInterval(30 + 600), after: 600)
        #expect(expired.count == 1)
        for event in expired { reducer.apply(event) }
        #expect(reducer.sessions["s"]?.status == .done)
        #expect(reducer.sessions["s"]?.completionID != nil)
    }

    @Test("rule 6: a PostToolUse landing after Stop does not reopen the turn")
    func lateReceipt() {
        var reducer = reduce([(start, 0), (stop(), 30)])
        let completion = reducer.sessions["s"]?.completionID
        #expect(completion != nil)
        reducer.apply(parse(#"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Bash","tool_response":{"stdout":"ok"}}"#, at: 31)!)
        #expect(reducer.sessions["s"]?.status == .done)
        #expect(reducer.sessions["s"]?.completionID == completion)
        #expect(reducer.sessions["s"]?.hasUnreadCompletion == true)
        // A real next step still starts a turn.
        reducer.apply(parse(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Read"}"#, at: 40)!)
        #expect(reducer.sessions["s"]?.status == .working)
    }

    // MARK: Through the store

    @Test("the store settles a held Stop when its last subagent stops, and via the sweep backstop")
    func storeReleases() async {
        let store = SessionStore()
        _ = await store.ingest(Data(start.utf8), receivedAt: t0)
        _ = await store.ingest(Data(#"{"hook_event_name":"SubagentStart","session_id":"s","agent_id":"bg","agent_type":"Explore"}"#.utf8),
                               receivedAt: t0.addingTimeInterval(5))
        _ = await store.ingest(Data(stop(tasks: #"[{"id":"bg","type":"subagent","status":"running"}]"#).utf8),
                               receivedAt: t0.addingTimeInterval(30))
        #expect(await store.snapshot(now: t0.addingTimeInterval(31)).sessions.first?.status == .working)
        _ = await store.ingest(Data(#"{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"bg","agent_type":"Explore"}"#.utf8),
                               receivedAt: t0.addingTimeInterval(200))
        let settled = await store.snapshot(now: t0.addingTimeInterval(201)).sessions.first
        #expect(settled?.status == .done)
        #expect(settled?.hasUnreadCompletion == true)

        let other = SessionStore()
        _ = await other.ingest(Data(start.utf8), receivedAt: t0)
        _ = await other.ingest(Data(stop(tasks: #"[{"id":"w","type":"workflow","status":"running"}]"#).utf8),
                               receivedAt: t0.addingTimeInterval(30))
        await other.sweep(now: t0.addingTimeInterval(30 + SessionStore.heldStopBackstop))
        #expect(await other.snapshot(now: t0.addingTimeInterval(700)).sessions.first?.status == .done)
    }
}
