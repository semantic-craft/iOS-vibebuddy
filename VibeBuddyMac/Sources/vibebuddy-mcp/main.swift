import Foundation
import Darwin
import VibeBuddyMacCore

@main
struct VibeBuddyMCP {
    @MainActor
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let argv = Array(CommandLine.arguments.dropFirst())
        let executor = HistoryToolExecutor(reader: .forCurrentRun())
        if argv.first == "setup" {
            guard argv == ["setup"] else { fail(HistoryToolError.invalidArguments("Usage: vibebuddy-mcp setup"), code: 2) }
            let setup = HistoryConnectionSetup(executablePath: runningExecutablePath())
            FileHandle.standardOutput.write(Data(HistoryCLI.output(setup.instructions()).utf8))
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
        } catch HistoryToolError.invalidValue(let message) {
            fail(HistoryToolError.invalidValue(message), code: argv.first == "call" ? 1 : 2)
        } catch HistoryToolError.invalidArguments(let message) {
            fail(HistoryToolError.invalidArguments(message), code: argv.first == "call" ? 1 : 2)
        } catch { fail(error, code: 1) }
    }

    /// A bundled auxiliary executable must not use the enclosing app's executable URL.
    private static func runningExecutablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else {
            fail(HistoryToolError.executionFailed("Unable to determine the running executable path."), code: 1)
        }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            fail(HistoryToolError.executionFailed("Unable to determine the running executable path."), code: 1)
        }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
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
