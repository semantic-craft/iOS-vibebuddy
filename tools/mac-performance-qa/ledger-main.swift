import Foundation
import XCTest

@main
struct LedgerProbe {
    static func main() {
        let suite = ToolLedgerPerformanceTests.defaultTestSuite
        suite.run()
        guard let run = suite.testRun, run.executionCount == 1,
              run.skipCount == 0, run.hasSucceeded else { exit(1) }
    }
}
