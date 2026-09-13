import Foundation
import Testing
@testable import VibeBuddyMacCore

@Suite("Dashboard right slot")
struct RightSlotStateTests {
    typealias S = RightSlotState

    @Test func transitionsFollowTheTicketTable() {
        let cases: [(S, S.Event, S)] = [
            (S(), .open(.output), S(mode: .pane, tool: .output, restore: .pane)),
            (S(mode: .pane, tool: .changes, restore: .pane), .select(.activity), S(mode: .pane, tool: .activity, restore: .pane)),
            (S(mode: .pane, tool: .changes, expanded: true, restore: .pane), .close, S(mode: .shelf, tool: .changes, restore: .shelf)),
            (S(), .toggleRail, S(mode: .rail, restore: .shelf)),
            (S(mode: .rail, restore: .shelf), .toggleRail, S(mode: .shelf, restore: .shelf)),
            (S(mode: .pane, tool: .output, restore: .pane), .toggleRail, S(mode: .rail, tool: .output, restore: .pane)),
            // Hide then re-expand brings back the pane on the same tab.
            (S(mode: .rail, tool: .output, restore: .pane), .toggleRail, S(mode: .pane, tool: .output, restore: .pane)),
            (S(mode: .rail, tool: .output, restore: .pane), .open(.changes), S(mode: .pane, tool: .changes, restore: .pane)),
            (S(mode: .pane, restore: .pane), .toggleExpanded, S(mode: .pane, expanded: true, restore: .pane)),
            (S(), .toggleExpanded, S()),
        ]
        for (start, event, expected) in cases {
            #expect(start.reduced(event) == expected, "\(start.rawValue) + \(event)")
        }
    }

    @Test func layoutDegradesTheSlotBeforeTheReadingColumn() {
        // 1180-wide default window: 1180 − 216 sidebar − 240 list = 724.
        #expect(S().layout(availableWidth: 724) == .shelf)
        #expect(S(mode: .pane, restore: .pane).layout(availableWidth: 724) == .pane(width: 320))
        // 1400 wide: the pane grows with the column but stays inside its band.
        #expect(S(mode: .pane, restore: .pane).layout(availableWidth: 944) == .pane(width: 396))
        #expect(S(mode: .pane, restore: .pane).layout(availableWidth: 2000) == .pane(width: 560))
        // 1080 wide (624 for the column): a pane cannot sit beside a readable
        // column, so it goes full-width with a way back; the shelf still fits.
        #expect(S(mode: .pane, restore: .pane).layout(availableWidth: 624) == .full(forced: true))
        #expect(S().layout(availableWidth: 624) == .shelf)
        // 940 minimum window (484): even the shelf collapses to the rail.
        #expect(S().layout(availableWidth: 484) == .rail)
        #expect(S(mode: .rail, restore: .shelf).layout(availableWidth: 2000) == .rail)
        #expect(S(mode: .pane, expanded: true, restore: .pane).layout(availableWidth: 2000) == .full(forced: false))
    }

    @Test func roundTripsThroughAppStorage() {
        let state = S(mode: .rail, tool: .activity, expanded: true, restore: .pane)
        #expect(S(rawValue: state.rawValue) == state)
        #expect(S(rawValue: "pane:bogus:0:shelf") == nil)
        #expect(S(rawValue: "") == nil)
        // A stored restore of "rail" can never trap the slot; it is coerced to shelf.
        #expect(S(rawValue: "rail:changes:0:rail")?.reduced(.toggleRail).mode == .shelf)
    }
}
