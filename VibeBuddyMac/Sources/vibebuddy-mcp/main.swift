import Foundation
import VibeBuddyMacCore

@main
struct VibeBuddyMCP {
    static func main() async {
        let request: (tool: String, arguments: [String: Any])
        do { request = try HistoryCLI.parse(Array(CommandLine.arguments.dropFirst())) }
        catch { fail(error, code: 2) }
        let directory = ProcessInfo.processInfo.environment["VIBEBUDDY_HISTORY_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        let repository = SessionHistoryRepository(cacheDirectory: directory, readOnly: true)
        do {
            let text: String
            if request.tool == "vibebuddy_get_session" {
                text = try await HistoryTools.getSession(arguments: request.arguments, repository: repository)
            } else if request.tool == "vibebuddy_get_summary" {
                text = try await HistoryTools.getSummary(arguments: request.arguments, repository: repository)
            } else {
                guard await repository.hasUsableIndex() else { fail(HistoryToolError.noIndex, code: 2) }
                text = try HistoryTools.call(request.tool, arguments: request.arguments, snapshot: await repository.snapshot())
            }
            FileHandle.standardOutput.write(Data(HistoryCLI.output(text).utf8))
        } catch HistoryToolError.invalidArguments(let message) {
            fail(HistoryToolError.invalidArguments(message), code: 2)
        } catch { fail(error, code: 1) }
    }
    private static func fail(_ error: Error, code: Int32) -> Never {
        FileHandle.standardError.write(Data("vibebuddy-mcp: \(error.localizedDescription)\n".utf8))
        exit(code)
    }
}
