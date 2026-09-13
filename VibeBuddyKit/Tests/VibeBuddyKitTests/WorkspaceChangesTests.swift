import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Workspace changes count projection")
struct WorkspaceChangesTests {
    private func changes(stat: String, unavailable: String? = nil) -> WorkspaceChanges {
        WorkspaceChanges(scope: .uncommitted, baseline: "HEAD", attribution: "", files: [], stat: stat, unavailableReason: unavailable)
    }

    @Test func summaryLineYieldsAddedAndDeleted() {
        let stat = " a.swift | 10 +++++-----\n b.swift | 5 +++++\n 2 files changed, 187 insertions(+), 4 deletions(-)\n"
        #expect(changes(stat: stat).addedLineCount == 187)
        #expect(changes(stat: stat).deletedLineCount == 4)
        let single = " a.swift | 1 +\n 1 file changed, 1 insertion(+)\n"
        #expect(changes(stat: single).addedLineCount == 1)
        #expect(changes(stat: single).deletedLineCount == 0)
    }

    @Test func cleanComparisonIsZeroButUnreadableIsUnknown() {
        #expect(changes(stat: "").addedLineCount == 0)
        #expect(changes(stat: "\n").addedLineCount == 0)
        #expect(changes(stat: "", unavailable: "No accessible local workspace for this session.").addedLineCount == nil)
        #expect(changes(stat: " 1 file changed, 3 insertions(+)", unavailable: "Git could not read").addedLineCount == nil)
        // A summary we cannot parse is unknown, not zero.
        #expect(changes(stat: " 1 file changed, 3 insertions").addedLineCount == nil)
        #expect(changes(stat: "garbage").addedLineCount == nil)
    }
}
