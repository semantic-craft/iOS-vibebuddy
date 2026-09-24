import Foundation
import Testing

/// Every runtime hook script hands curl the daemon token through a file
/// descriptor, never argv: argv is readable by every local user through `ps`
/// for as long as curl runs, and Grok runs the status line wrapper every few
/// hundred ms. A fake `curl` on PATH records its argv, the headers it would
/// read from each `-H @file`, and the body on its stdin.
@Suite("Hook scripts keep the daemon token out of argv")
struct HookTokenArgvTests {
    private static let hooks = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("hooks")

    struct Hook: Sendable, CustomTestStringConvertible {
        let script: String
        let shell: String
        let arguments: [String]
        let input: String
        /// The request paths, in order, when a token is present.
        let paths: [String]
        /// Whether the body is the hook input verbatim.
        let forwardsInput: Bool
        /// Whether it still calls curl, header-less, with no token.
        let callsWithoutToken: Bool
        var testDescription: String { script }
    }

    static let cases: [Hook] = [
        Hook(script: "vibebuddy-forward.sh", shell: "/bin/bash", arguments: ["claude"],
             input: #"{"session_id":"s","hook_event_name":"Stop"}"#,
             paths: ["/hook?agent=claude"], forwardsInput: true, callsWithoutToken: true),
        Hook(script: "approval-hook.sh", shell: "/bin/sh", arguments: ["grok"],
             input: #"{"sessionId":"s","toolName":"bash"}"#,
             paths: ["/approval?agent=grok"], forwardsInput: true, callsWithoutToken: true),
        Hook(script: "vibebuddy-statusline.sh", shell: "/bin/sh", arguments: ["grok", "0a1b"],
             input: "{\"session_id\":\"g\"}\n",
             paths: ["/statusline?agent=grok"], forwardsInput: false, callsWithoutToken: false),
        Hook(script: "cursor-followup.sh", shell: "/bin/bash", arguments: [],
             input: #"{"hook_event_name":"stop","conversation_id":"c"}"#,
             paths: ["/hook?agent=cursor", "/cursor-followup"], forwardsInput: true, callsWithoutToken: true),
        Hook(script: "capture-terminal.sh", shell: "/bin/bash", arguments: [],
             input: #"{"session_id":"s","hook_event_name":"SessionStart"}"#,
             paths: ["/terminal"], forwardsInput: false, callsWithoutToken: true),
    ]

    /// Each call leaves `<n>.argv` (one argument per line), `<n>.headers` and
    /// `<n>.body` in `$VB_CURL_LOG`.
    private static let fakeCurl = """
    #!/bin/sh
    n=$(mktemp "$VB_CURL_LOG/call.XXXXXX")
    printf '%s\\n' "$@" > "$n.argv"
    : > "$n.headers"
    prev=
    for a in "$@"; do
      if [ "$prev" = -H ]; then
        case "$a" in @*) cat "${a#@}" >> "$n.headers" ;; *) printf '%s\\n' "$a" >> "$n.headers" ;; esac
      fi
      prev=$a
    done
    cat > "$n.body"
    exit 0
    """

    struct Call { let argv: String, headers: String, body: String }

    @Test("the token reaches curl as a header, never as an argument", arguments: cases, [true, false])
    func tokenStaysOutOfArgv(hook: Hook, withToken: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vb-token-argv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin"), log = root.appendingPathComponent("log")
        let support = root.appendingPathComponent("support")
        for dir in [bin, log, support] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let curl = bin.appendingPathComponent("curl")
        try Data(Self.fakeCurl.utf8).write(to: curl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        let token = "vb-secret-\(UUID().uuidString)"
        let tokenFile = support.appendingPathComponent("token")
        if withToken { try Data((token + "\n").utf8).write(to: tokenFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: hook.shell)
        process.arguments = [Self.hooks.appendingPathComponent(hook.script).path] + hook.arguments
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path + "/",
                               "VB_CURL_LOG": log.path, "VIBEBUDDY_PORT": "18998",
                               "VIBEBUDDY_TOKEN_FILE": tokenFile.path, "VIBEBUDDY_SUPPORT_DIR": support.path,
                               "VIBEBUDDY_GHOSTTY_PROBE": "0"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Not `waitUntilExit()`: see CursorFollowupTimeoutTests.
        let (exited, exit) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exit.finish() }
        try process.run()
        input.fileHandleForWriting.write(Data(hook.input.utf8))
        try input.fileHandleForWriting.close()
        for await _ in exited {}
        #expect(process.terminationStatus == 0)
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)

        let calls = try Self.calls(in: log)
        #expect(calls.count == (withToken || hook.callsWithoutToken ? hook.paths.count : 0))
        for (call, path) in zip(calls, hook.paths) {
            #expect(call.argv.contains("http://127.0.0.1:18998\(path)"), "\(call.argv)")
            #expect(!call.argv.contains(token))
            #expect(!call.argv.contains("Authorization"))
            let header = call.headers.split(separator: "\n").filter { $0.hasPrefix("Authorization") }
            #expect(header == (withToken ? ["Authorization: Bearer \(token)"] : []))
            if hook.forwardsInput { #expect(call.body == hook.input) }
        }
    }

    /// The calls in the order curl was run: the request paths say which is which.
    private static func calls(in log: URL) throws -> [Call] {
        let names = try FileManager.default.contentsOfDirectory(atPath: log.path).filter { $0.hasSuffix(".argv") }
        let read = { (name: String) in
            (try? String(contentsOf: log.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        return names.map { argv in
            let stem = String(argv.dropLast(".argv".count))
            return Call(argv: read(argv), headers: read(stem + ".headers"), body: read(stem + ".body"))
        }.sorted { lhs, rhs in
            // cursor-followup.sh is the only two-call script: /hook first.
            lhs.argv.contains("/hook?") && !rhs.argv.contains("/hook?")
        }
    }
}
