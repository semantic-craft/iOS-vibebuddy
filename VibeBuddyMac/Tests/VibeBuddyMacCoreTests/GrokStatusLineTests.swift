import Foundation
import Testing
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// A status line document as grok 1.0.41 sent it mid-session (captured
/// 2026-09-24 from a real TUI; paths shortened).
private let grokStatusLineJSON = #"""
{"schema_version":1,"cwd":"/x/proj","session_id":"01a0d25f-a954-7491-9008-712b416c1001",
 "session_name":"User ping requesting simple pong word reply",
 "transcript_path":"/x/gh/sessions/%2Fx%2Fproj/01a0d25f-a954-7491-9008-712b416c1001/updates.jsonl",
 "model":{"id":"grok-4.7","display_name":"Grok 4.7"},
 "workspace":{"current_dir":"/x/proj","repo_root":"/x/proj","branch":"main"},
 "version":"1.0.41",
 "cost":{"total_cost_usd":0.01555024,"total_duration_ms":18857,"total_api_duration_ms":2612},
 "context_window":{"context_window_size":500000,"context_tokens":24157,"session_input_tokens":24119,
   "session_output_tokens":31,"session_usage":{"input_tokens":22327,"output_tokens":31,
   "cache_creation_input_tokens":0,"cache_read_input_tokens":1792},
   "used_percentage":5,"remaining_percentage":95,"auto_compact_threshold_percent":80},
 "effort":{"level":"xhigh"},"trigger":"state"}
"""#

@Suite("Grok status line and session registry")
struct GrokStatusLineTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let id = "01a0d25f-a954-7491-9008-712b416c1001"

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vb-grok-sl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Grok's payload decodes to the live context, cost and branch, never a quota")
    func decode() throws {
        let sample = try #require(StatusLineSample.decode(json(grokStatusLineJSON), agent: .grok))
        #expect(sample.agent == .grok)
        #expect(sample.model == "Grok 4.7")
        #expect(sample.contextTokens == 24_157)          // context_tokens, not 5% of 500k
        #expect(sample.contextWindow == 500_000)
        #expect(sample.costUSD == 0.01555024)
        #expect(sample.effort == "xhigh")
        #expect(sample.branch == "main")
        #expect(sample.sessionName == "User ping requesting simple pong word reply")
        #expect(sample.usageSnapshot(fetchedAt: now) == nil)

        // Before anything carries a price there is no cost, and none is invented.
        var doc = json(grokStatusLineJSON)
        doc["cost"] = ["total_duration_ms": 158, "total_api_duration_ms": 0]
        doc["context_window"] = ["context_window_size": 500_000, "used_percentage": 1]
        let early = try #require(StatusLineSample.decode(doc, agent: .grok))
        #expect(early.costUSD == nil)
        #expect(early.contextTokens == 5_000)
    }

    @Test("/statusline?agent=grok fills the Grok row; a sample never crosses agents")
    func route() async throws {
        let store = SessionStore(grokHome: try temporaryDirectory())
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: id, agent: .grok,
                                     cwd: "/x/proj", timestamp: now))
        let srv = VibeBuddyServer(store: store, token: "t0k", port: 9876, usageFeed: AccountUsageLiveFeed())
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/statusline?agent=nope", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: grokStatusLineJSON)) { res in
                #expect(res.status == .badRequest)
            }
            // Claude's route does not touch a Grok row with the same id.
            try await client.execute(uri: "/statusline", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: grokStatusLineJSON)) { res in
                #expect(res.status == .ok)
            }
            #expect(await store.snapshot(now: now).sessions.first?.contextTokens == nil)
            try await client.execute(uri: "/statusline?agent=grok", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: grokStatusLineJSON)) { res in
                #expect(res.status == .ok)
            }
        }
        let session = try #require(await store.snapshot(now: now).sessions.first { $0.id == id })
        #expect(session.status == .working)
        #expect(session.contextTokens == 24_157)
        #expect(session.contextWindow == 500_000)
        #expect(session.costUSD == 0.01555024)
        #expect(session.branch == "main")
        #expect(session.observations?.contains { $0.source == .statusline } == true)
    }

    @Test("a session that leaves Grok's registry stops working; one never listed is left alone")
    func registryRetires() async throws {
        let grokHome = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: grokHome) }
        let registry = grokHome.appendingPathComponent("active_sessions.json")
        func list(_ ids: [String], pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                  openedAt: String = "2099-01-01T00:00:00.000001Z") throws {
            let entries = ids.map { #"{"session_id":"\#($0)","pid":\#(pid),"cwd":"/x","opened_at":"\#(openedAt)"}"# }
            try Data("[\(entries.joined(separator: ","))]".utf8).write(to: registry)
        }
        let store = SessionStore(grokHome: grokHome)
        for session in ["listed", "unlisted"] {
            await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: session, agent: .grok,
                                         cwd: "/x", timestamp: now))
        }
        try list(["listed"])
        await store.sweep(now: now.addingTimeInterval(60))
        #expect(await store.hasSession("listed"))
        try list([])
        await store.sweep(now: now.addingTimeInterval(120))
        #expect(await !store.hasSession("listed"))
        #expect(await store.hasSession("unlisted"))

        // Killed outright: the entry stays but the pid is gone (or reused).
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "killed", agent: .grok,
                                     cwd: "/x", timestamp: now))
        try list(["killed"])
        await store.sweep(now: now.addingTimeInterval(180))
        #expect(await store.hasSession("killed"))
        try list(["killed"], openedAt: "2001-01-01T00:00:00Z")   // this pid started after that
        await store.sweep(now: now.addingTimeInterval(240))
        #expect(await !store.hasSession("killed"))

        // An unreadable registry says nothing.
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "kept", agent: .grok,
                                     cwd: "/x", timestamp: now))
        try list(["kept"])
        await store.sweep(now: now.addingTimeInterval(300))
        try Data("[{\"session_id\":".utf8).write(to: registry)
        await store.sweep(now: now.addingTimeInterval(360))
        try FileManager.default.removeItem(at: registry)
        await store.sweep(now: now.addingTimeInterval(420))
        #expect(await store.hasSession("kept"))
    }

    @Test("registry dates carry microseconds")
    func registryDate() throws {
        let date = try #require(GrokActiveSessions.date("2026-09-24T07:44:40.200616Z"))
        #expect(abs(date.timeIntervalSince1970 - 1_790_235_880.2) < 0.01)
    }

    // MARK: - Installer

    private func home() throws -> (HookInstallerTests.Home, HookInstaller) {
        let home = try HookInstallerTests.Home()
        try home.mkdir(".grok")
        return (home, home.installer)
    }

    private let userConfig = """
    [cli]
    auto_update = true

    [ui]
    permission_mode = "always-approve" # keep me

    [[marketplace.sources]]
    name = "xAI Official"
    items = [
      [1, 2],
    ]

    """

    @Test("install appends [ui.status_line]; uninstall restores the file byte for byte")
    func installAppends() throws {
        let (home, installer) = try home()
        defer { home.remove() }
        try home.write(".grok/config.toml", userConfig)
        #expect(installer.install([.grok]).failures == 0)
        let text = String(decoding: try #require(home.bytes(".grok/config.toml")), as: UTF8.self)
        #expect(text.hasPrefix(userConfig))
        let toml = GrokTOMLText(text)
        guard case .table(let range) = toml.locate() else { Issue.record("no table"); return }
        #expect(toml.value(of: "type", in: range) == "command")
        let command = try #require(toml.value(of: "command", in: range))
        #expect(command == ShellWords.quoted(home.paths.script("vibebuddy-statusline.sh").path)
            + " grok " + home.paths.grokKey)
        #expect(ShellWords.split(command) == [home.paths.script("vibebuddy-statusline.sh").path, "grok", home.paths.grokKey])
        #expect(installer.status().first { $0.agent == .grok }?.statusLineWired == true)

        // Idempotent.
        let before = home.bytes(".grok/config.toml")
        #expect(installer.install([.grok]).failures == 0)
        #expect(home.bytes(".grok/config.toml") == before)

        #expect(installer.uninstall([.grok]).failures == 0)
        #expect(home.bytes(".grok/config.toml") == Data(userConfig.utf8))
        #expect(!FileManager.default.fileExists(atPath: home.paths.grokStatusLineOriginal.path))
    }

    @Test("a user's command row is wrapped, run by the wrapper, and put back on uninstall")
    func wrapsUserCommand() throws {
        let (home, installer) = try home()
        defer { home.remove() }
        let original = userConfig + """

        [ui.status_line]
        type = "command"
        command = "~/.grok/my status.sh" # mine
        padding = 2

        [models]
        default = "grok-build"

        """
        try home.write(".grok/config.toml", original)
        try home.write(".grok/my status.sh", "#!/bin/sh\ncat > \"$HOME/seen.json\"\necho user-row\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.url(".grok/my status.sh").path)
        #expect(installer.enableStatusLine(.grok).failures == 0)
        let text = String(decoding: try #require(home.bytes(".grok/config.toml")), as: UTF8.self)
        #expect(text.contains("padding = 2") && text.contains("[models]") && text.contains("# keep me"))
        #expect(!text.contains("my status.sh"))
        #expect(String(decoding: try #require(home.bytes(
            "Library/Application Support/vibebuddy/grok-statusline-original.\(home.paths.grokKey).cmd")), as: UTF8.self)
            == "~/.grok/my status.sh")
        #expect(!home.exists(".grok/hooks/vibebuddy.json"), "the status line action touches no hooks")

        // The wrapper runs the user's row (an executable path with a space,
        // `~/` expanded, as Grok would) and waits for its forward.
        let toml = GrokTOMLText(text)
        guard case .table(let range) = toml.locate() else { Issue.record("no table"); return }
        let fakeBin = home.url("fakebin")
        try home.write("fakebin/curl", "#!/bin/sh\nsleep 0.5\ncat > \"$HOME/forwarded.json\"\necho \"$@\" > \"$HOME/curl-args\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBin.appendingPathComponent("curl").path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try #require(toml.value(of: "command", in: range))]
        process.environment = ["PATH": "\(fakeBin.path):/usr/bin:/bin", "HOME": home.root.path,
                               "VIBEBUDDY_TOKEN": "t0k", "VIBEBUDDY_PORT": "18999",
                               "VIBEBUDDY_SUPPORT_DIR": home.paths.support.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("{\"session_id\":\"g\"}\n".utf8))
        try input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(String(decoding: printed, as: UTF8.self) == "user-row\n")
        #expect(home.bytes("seen.json") == Data("{\"session_id\":\"g\"}\n".utf8))
        // Present when the wrapper exits: Grok would have killed a straggler.
        #expect(home.bytes("forwarded.json") == Data("{\"session_id\":\"g\"}".utf8))
        #expect(String(decoding: home.bytes("curl-args") ?? Data(), as: UTF8.self)
            .contains("http://127.0.0.1:18999/statusline?agent=grok"))

        #expect(installer.uninstall([.grok]).failures == 0)
        #expect(home.bytes(".grok/config.toml") == Data(original.utf8))
    }

    @Test("builtin rows, inline tables and dotted keys are left alone; no config is created and removed cleanly")
    func leavesOtherShapesAlone() throws {
        for config in [
            "[ui.status_line]\ntype = \"builtin\"\nitems = [\"cwd\"]\n",
            "[ui]\nstatus_line = { type = \"command\", command = \"x\" }\n",
            "[ui]\nstatus_line.type = \"command\"\n",
            "ui = { permission_mode = \"ask\" }\n",
            "[ui.status_line]\ncommand = \"\"\"\nx\n\"\"\"\n",
        ] {
            let (home, installer) = try home()
            defer { home.remove() }
            try home.write(".grok/config.toml", config)
            let report = installer.install([.grok])
            #expect(report.failures == 0)
            #expect(report.text.contains("status line left alone"), "\(config)")
            #expect(home.bytes(".grok/config.toml") == Data(config.utf8), "\(config)")
            #expect(installer.uninstall([.grok]).failures == 0)
            #expect(home.bytes(".grok/config.toml") == Data(config.utf8))
        }

        let (home, installer) = try home()
        defer { home.remove() }
        #expect(installer.install([.grok]).failures == 0)
        #expect(home.exists(".grok/config.toml"))
        #expect(installer.uninstall([.grok]).failures == 0)
        #expect(!home.exists(".grok/config.toml"), "a config only vibebuddy made is removed")
    }

    @Test("a disabled row with other keys becomes ours and comes back disabled")
    func disabledRow() throws {
        let (home, installer) = try home()
        defer { home.remove() }
        let original = "[ui.status_line]\ntype = \"off\"\nrefresh_interval = 60\n"
        try home.write(".grok/config.toml", original)
        #expect(installer.install([.grok]).failures == 0)
        let text = String(decoding: try #require(home.bytes(".grok/config.toml")), as: UTF8.self)
        #expect(text.hasPrefix("[ui.status_line]\ntype = \"command\"\ncommand = '"))
        #expect(text.hasSuffix("refresh_interval = 60\n"))
        #expect(home.bytes("Library/Application Support/vibebuddy/grok-statusline-original.\(home.paths.grokKey).cmd")
            == Data())
        #expect(installer.uninstall([.grok]).failures == 0)
        #expect(home.bytes(".grok/config.toml") == Data(original.utf8))
    }
}
