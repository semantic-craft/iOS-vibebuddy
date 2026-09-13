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
        let repository = SessionHistoryRepository(cacheDirectory: directory, readOnly: true)
        let executor = HistoryToolExecutor(repository: repository)
        if argv.isEmpty {
            // When every registered tool needs the index, fail startup helpfully.
            // Adding source-only/show or live tools allows them to start without it;
            // each indexed call still checks its own prerequisite in the executor.
            let names = HistoryTools.definitions().compactMap { $0["name"] as? String }
            if names.allSatisfy(HistoryToolExecutor.requiresIndex), !(await repository.hasUsableIndex()) {
                fail(HistoryToolError.noIndex, code: 2)
            }
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
