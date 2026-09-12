import XCTest
import VibeBuddyKit
@testable import VibeBuddyMacCore

final class TaskGoalTests: XCTestCase {
    func testOriginalGoalRequiresNewSessionEvidence() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var reducer = SessionReducer()
        reducer.apply(HookEvent(kind: .userPromptSubmit, sessionID: "midway", cwd: "/tmp/project", message: "Continue", timestamp: now))
        XCTAssertNil(reducer.sessions["midway"]?.firstUserPrompt)
        XCTAssertEqual(reducer.sessions["midway"]?.taskGoal, "project")
        let data = Data(#"{"hook_event_name":"SessionStart","session_id":"new","cwd":"/tmp/project","source":"startup"}"#.utf8)
        let start = try XCTUnwrap(HookParser.parse(data, receivedAt: now))
        XCTAssertTrue(start.startsNewSession)
        reducer.apply(start)
        reducer.apply(HookEvent(kind: .userPromptSubmit, sessionID: "new", message: "Original goal", timestamp: now))
        reducer.apply(HookEvent(kind: .userPromptSubmit, sessionID: "new", message: "Follow-up", timestamp: now))
        XCTAssertEqual(reducer.sessions["new"]?.taskGoal, "Original goal")
    }
}
