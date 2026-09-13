import Foundation
import VibeBuddyMacCore

@main
struct VibeBuddyMCP {
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        let directory = ProcessInfo.processInfo.environment["VIBEBUDDY_HISTORY_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        if argv.first == "index" {
            guard argv == ["index"] || argv == ["index", "--rebuild"] else {
                fail(HistoryToolError.invalidArguments("Usage: vibebuddy-mcp index [--rebuild]"), code: 2)
            }
            do {
                let repository = SessionHistoryRepository(grokHome: GrokHome.url, cacheDirectory: directory)
                let snapshot = try await repository.index(rebuild: argv.contains("--rebuild"))
                let text = snapshot.map { "Indexed \($0.sessions.count) sessions.\n" + $0.issues.joined(separator: "\n") }
                    ?? "Index already exists. Use --rebuild to refresh all sources."
                FileHandle.standardOutput.write(Data(HistoryCLI.output(text).utf8))
                return
            } catch { fail(error, code: 2) }
        }
        let request: (tool: String, arguments: [String: Any])
        do { request = try HistoryCLI.parse(Array(CommandLine.arguments.dropFirst())) }
        catch { fail(error, code: 2) }
        let repository = SessionHistoryRepository(grokHome: GrokHome.url, cacheDirectory: directory, readOnly: true)
        do {
            let text: String
            if request.tool == "vibebuddy_get_session" {
                text = try await HistoryTools.getSession(arguments: request.arguments, repository: repository)
            } else {
                guard await repository.hasUsableIndex() else { fail(HistoryToolError.noIndex, code: 2) }
                if request.tool == "vibebuddy_search" {
                    text = try await HistoryTools.search(arguments: request.arguments, repository: repository)
                } else {
                    text = try HistoryTools.call(request.tool, arguments: request.arguments, snapshot: await repository.snapshot())
                }
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
