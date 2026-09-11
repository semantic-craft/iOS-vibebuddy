import Testing
@testable import VibeBuddyKit

struct RealtimeToolIdentityTests {
    @Test func interruptedItemAndCallStayRetiredWhileNewResponseWorks() {
        var filter = RealtimeResponseFilter()
        func accepts(_ event: [String: Any]) -> Bool { filter.accept(event) }
        #expect(accepts(["type": "response.created", "response": ["id": "old"]]))
        #expect(accepts(["type": "response.output_item.added", "response_id": "old", "item": ["id": "item-old"]]))
        #expect(accepts(["type": "response.function_call_arguments.done", "response_id": "old", "item_id": "item-old", "call_id": "call-old"]))
        #expect(accepts(["type": "input_audio_buffer.speech_started"]))
        #expect(filter.cancelledCalls == ["call-old"])
        #expect(!accepts(["type": "response.function_call_arguments.done", "item_id": "item-old", "call_id": "late"]))
        #expect(accepts(["type": "response.created", "response": ["id": "new"]]))
        #expect(!accepts(["type": "response.function_call_arguments.done", "response_id": "new", "item_id": "item-old", "call_id": "conflict"]))
        #expect(filter.rejection != nil)
        #expect(!accepts(["type": "response.function_call_arguments.done", "call_id": "unknown"]))
        #expect(filter.rejection != nil)
        #expect(accepts(["type": "response.function_call_arguments.done", "response_id": "new", "call_id": "fresh"]))
        #expect(accepts(["type": "input_audio_buffer.speech_started"]))
        #expect(filter.cancelledCalls == ["fresh"])
    }

    @Test func continuationResponseDoesNotHideAnOlderPendingAction() {
        var filter = RealtimeResponseFilter()
        _ = filter.accept(["type": "response.created", "response": ["id": "r1"]])
        _ = filter.accept(["type": "response.function_call_arguments.done", "response_id": "r1", "call_id": "status"])
        _ = filter.accept(["type": "response.function_call_arguments.done", "response_id": "r1", "call_id": "approve"])
        filter.completed(callID: "status")
        _ = filter.accept(["type": "response.created", "response": ["id": "r2"]])
        _ = filter.accept(["type": "input_audio_buffer.speech_started"])
        #expect(filter.cancelledCalls == ["approve"])
        let late = filter.accept(["type": "response.function_call_arguments.done", "response_id": "r1", "call_id": "late"])
        #expect(!late)
    }

    @Test func releaseReportsCannotCrossAnAudioGeneration() {
        let gate = VoiceAudioReleaseGate()
        let stopped = gate.advance()
        #expect(gate.accepts(stopped))
        let restarted = gate.advance()
        #expect(!gate.accepts(stopped))
        #expect(gate.accepts(restarted))
        let repeatedStop = gate.advance()
        #expect(!gate.accepts(restarted))
        #expect(gate.accepts(repeatedStop))
    }
}
