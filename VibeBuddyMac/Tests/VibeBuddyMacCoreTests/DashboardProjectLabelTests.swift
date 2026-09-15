import Testing
@testable import VibeBuddyMacCore

struct DashboardProjectLabelTests {
    @Test func sameNamedCheckoutsKeepDistinctParentLabels() {
        let paths = ["/Users/me/Projects/glaux-book", "/Users/me/.codex/worktrees/1962/glaux-book",
                     "/Users/me/.codex/worktrees/a4e0/glaux-book"]
        let batch = DashboardProjectLabel.labels(for: paths + [paths[0], "/other/Projects/different-name"])
        #expect(batch.count == 4)
        let labels = paths.map { batch[$0]! }
        #expect(labels.map(\.title) == ["glaux-book", "glaux-book", "glaux-book"])
        #expect(labels.map(\.parentPath) == ["Projects", "1962", "a4e0"])

        let nested = ["/work/one/shared/deep/repo", "/work/two/shared/deep/repo"]
        let nestedLabels = DashboardProjectLabel.labels(for: nested)
        #expect(nested.map { nestedLabels[$0]!.parentPath }
                == ["one/shared/deep", "two/shared/deep"])
    }

    @Test func remoteAndLegacyIdentitiesStayLiteral() {
        let names = ["https://github.com/example/repo", "git@github.com:example/repo.git", "repo", "/", ""]
        let labels = DashboardProjectLabel.labels(for: names)
        #expect(labels.count == names.count)
        for name in names {
            let label = labels[name]!
            #expect(label.title == name)
            #expect(label.parentPath == nil)
        }
    }
}
