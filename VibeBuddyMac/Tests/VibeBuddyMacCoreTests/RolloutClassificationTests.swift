import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("OH-2 rollout evidence to snapshot")
struct RolloutClassificationTests {
    private let now = Date()
    private let meta = #"{"type":"session_meta","payload":{"id":"test","originator":"Codex Desktop","cli_version":"0.153.4"}}"#
    private let started = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}"#

    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh2-\(UUID())")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/sessions"),
                                               withIntermediateDirectories: true)
        return home
    }
    private func write(_ text: String, home: URL, name: String = "test", at: Date? = nil) throws -> URL {
        let url = home.appendingPathComponent(".codex/sessions/rollout-\(name).jsonl")
        try Data((text + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: at ?? now], ofItemAtPath: url.path)
        return url
    }
    private func store(_ home: URL) -> SessionStore {
        SessionStore(diagnosticsHome: home, grokHome: home.appendingPathComponent("absent"))
    }

    @Test("real 0.153.4 start/tool/finish replay reaches snapshot without certification")
    func realLifecycle() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try #require(Bundle.module.url(forResource: "rollout-0.153.4", withExtension: "jsonl", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        _ = try write(text, home: home)
        let store = store(home)
        var parser = CodexRolloutParser()
        var kinds: [HookEvent.Kind] = []
        for line in text.split(separator: "\n") {
            for event in parser.parseEvents(Data(line.utf8), receivedAt: now) {
                kinds.append(event.kind)
                await store.ingest(event)
                let snapshot = await store.snapshot(now: event.timestamp)
                let session = try #require(snapshot.sessions.first)
                if [.userPromptSubmit, .preToolUse, .postToolUse].contains(event.kind) {
                    #expect(session.status == .working)
                } else if event.kind == .stop {
                    #expect(session.status == .done)
                }
                #expect(snapshot.rollout?.health == .unknownVersion)
                #expect(snapshot.rollout?.reasonCode == "versionUnverified")
                #expect(snapshot.rollout?.sourceVersion == "0.153.4")
            }
        }
        #expect(kinds.contains(.userPromptSubmit))
        #expect(kinds.contains(.preToolUse))
        #expect(kinds.contains(.postToolUse))
        #expect(kinds.last == .stop)
        #expect(!parser.turnActive)
    }

    @Test("future versions and metadata do not manufacture health or a last signal")
    func certificationIsSeparate() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        for version in ["0.153.4", "0.999.0"] {
            _ = try write(meta.replacingOccurrences(of: "0.153.4", with: version)
                + "\n" + started + "\n" + #"{"type":"future_optional_record","payload":[]}"#, home: home)
            let snapshot = await store(home).snapshot(now: now)
            #expect(snapshot.rollout?.reasonCode == "versionUnverified")
            #expect(snapshot.rollout?.sourceVersion == version)
            #expect(snapshot.rollout?.lastObservedAt == nil)
            #expect(snapshot.sessions.isEmpty)
        }
        _ = try write(meta.replacingOccurrences(of: "0.153.4", with: "0.153.3"), home: home)
        let metadata = await store(home).snapshot(now: now)
        #expect(metadata.rollout?.health == .eventsMissing)
        #expect(metadata.rollout?.lastObservedAt == nil)
        #expect(metadata.sessions.isEmpty)
    }

    @Test("corruption outranks fresh signals and newer readable threads without moving progress")
    func failuresAreIndependent() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        for damage in ["{broken", #"{"type":"event_msg","payload":{"type":"item_completed"}}"#,
                       #"{"type":"event_msg","payload":{"type":"task_started","turn_id":42}}"#] {
            _ = try write(meta + "\n" + damage, home: home, name: "broken", at: now.addingTimeInterval(-10))
            _ = try write(meta.replacingOccurrences(of: "0.153.4", with: "0.153.3") + "\n" + started,
                          home: home, name: "newer")
            let store = store(home)
            await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "appserver-thread", agent: .codex,
                observationSource: .appserver, timestamp: now))
            await store.ingest(HookEvent(kind: .stop, sessionID: "appserver-thread", agent: .codex,
                observationSource: .rollout, timestamp: now))
            let snapshot = await store.snapshot(now: now)
            #expect(snapshot.sessions.first?.status == .working)
            #expect(snapshot.observationDiagnostics?.first { $0.agent == .codex }?.sources
                .first { $0.source == .appserver }?.health == .healthy)
            #expect(snapshot.rollout?.health == .unknownVersion)
            #expect(snapshot.rollout?.reasonCode == "invalidSourceData")
            #expect(snapshot.rollout?.sourceVersion == "0.153.4")
            #expect(snapshot.rollout?.lastObservedAt == now)
        }
        _ = try write(meta.replacingOccurrences(of: #""id":"test",""#, with: "") + "\n" + started,
                      home: home, name: "broken")
        let missingIdentity = await store(home).snapshot(now: now)
        #expect(missingIdentity.rollout?.reasonCode == "invalidSourceData")
        let bad = try write(meta, home: home, name: "broken")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: bad.path)
        let unreadable = await store(home).snapshot(now: now)
        #expect(unreadable.rollout?.health == .sourceUnreadable)
        #expect(unreadable.rollout?.reasonCode != "versionUnverified")
    }

    @Test("runtime parse failure wins over an unverified file and survives cache refresh")
    func runtimeFailure() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        for version in ["0.153.3", "0.153.4"] {
            _ = try write(meta.replacingOccurrences(of: "0.153.4", with: version) + "\n" + started, home: home)
            let store = store(home)
            _ = await store.snapshot(now: now)
            await store.recordSourceSignal(agent: .codex, source: .rollout, health: .unknownVersion, at: now)
            for at in [now, now.addingTimeInterval(31)] {
                let snapshot = await store.snapshot(now: at)
                #expect(snapshot.rollout?.reasonCode == "invalidSourceData")
                #expect(snapshot.rollout?.sourceVersion == version)
                #expect(snapshot.sessions.isEmpty)
            }
        }
    }
}

private extension Snapshot {
    var rollout: ObservationSourceDiagnostic? {
        observationDiagnostics?.first { $0.agent == .codex }?.sources.first { $0.source == .rollout }
    }
}
