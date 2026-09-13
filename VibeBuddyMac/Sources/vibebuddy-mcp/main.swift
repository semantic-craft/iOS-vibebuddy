import Foundation
import Darwin
import VibeBuddyMacCore

@main
struct VibeBuddyMCP {
    @MainActor
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
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
        let repository = SessionHistoryRepository(grokHome: GrokHome.url, cacheDirectory: directory, readOnly: true)
        let executor = HistoryToolExecutor(repository: repository)
        if argv.first == "setup" {
            guard argv == ["setup"] else { fail(HistoryToolError.invalidArguments("Usage: vibebuddy-mcp setup"), code: 2) }
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let setup = HistoryConnectionSetup(executablePath: executable.standardizedFileURL.resolvingSymlinksInPath().path)
            let text = setup.instructions(indexAvailable: await repository.hasUsableIndex())
            FileHandle.standardOutput.write(Data(HistoryCLI.output(text).utf8))
            return
        }
        if argv.isEmpty {
            do { try await serve(HistoryMCPServer(executor: executor)) }
            catch { fail(error, code: 1) }
            return
        }
        let request: (tool: String, arguments: [String: Any])
        do { request = try HistoryCLI.parse(argv) }
        catch { fail(error, code: 2) }
        do {
            let arguments = argv.first == "call" ? request.arguments : try HistoryTools.normalizeCLIArguments(request.tool, arguments: request.arguments)
            let text = try await executor.execute(request.tool, arguments: arguments)
            try FileHandle.standardOutput.write(contentsOf: Data(HistoryCLI.output(text).utf8))
        } catch HistoryToolError.noIndex { fail(HistoryToolError.noIndex, code: 2) }
        catch HistoryToolError.invalidValue(let message) {
            fail(HistoryToolError.invalidValue(message), code: argv.first == "call" ? 1 : 2)
        } catch HistoryToolError.invalidArguments(let message) {
            fail(HistoryToolError.invalidArguments(message), code: argv.first == "call" ? 1 : 2)
        } catch { fail(error, code: 1) }
    }

    /// Bounded newline framing. read(2) returns available bytes rather than
    /// waiting to fill a buffer, so interactive clients receive replies promptly.
    @MainActor
    private static func serve(_ server: HistoryMCPServer) async throws {
        let frameLimit = 1024 * 1024
        var pending = Data()
        var scannedBytes = 0
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw HistoryToolError.executionFailed("Unable to read MCP stdin")
            }
            if count == 0 {
                if !pending.isEmpty { throw HistoryToolError.executionFailed("MCP stdin ended before a newline delimiter") }
                return
            }
            pending.append(contentsOf: chunk.prefix(count))
            while let newline = pending.dropFirst(scannedBytes).firstIndex(of: 10) {
                guard pending.distance(from: pending.startIndex, to: newline) <= frameLimit else {
                    throw HistoryToolError.executionFailed("MCP request exceeds the 1 MiB frame limit")
                }
                let frame = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                scannedBytes = 0
                if let response = try await server.response(to: frame) {
                    try FileHandle.standardOutput.write(contentsOf: response + Data([10]))
                }
            }
            scannedBytes = pending.count
            guard pending.count <= frameLimit else { throw HistoryToolError.executionFailed("MCP request exceeds the 1 MiB frame limit") }
        }
    }

    private static func fail(_ error: Error, code: Int32) -> Never {
        FileHandle.standardError.write(Data("vibebuddy-mcp: \(error.localizedDescription)\n".utf8))
        exit(code)
    }
}
