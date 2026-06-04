# Remote Approval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a paired phone approve/deny a Claude Code tool use, but only for commands that aren't auto-allowed (i.e. when a prompting-mode Mac would prompt); on timeout/unreachable, defer to Claude's own behaviour.

**Architecture:** An opt-in blocking `PreToolUse` hook POSTs to a new localhost `/approval` endpoint. The daemon runs a conservative permission matcher (with a shell-chaining guard); allow-listed → respond `allow` immediately, deny-listed → `deny`, otherwise set `pendingApproval` on the session, broadcast to the phone, and hold the request on an `ApprovalRegistry` continuation until a token-gated `POST /decision` arrives or ~25s elapses (then respond empty → the hook prints nothing → Claude proceeds normally).

**Tech Stack:** Swift 6, Swift Testing, Hummingbird (server), SwiftUI (iOS), Python (installer), shell (hook).

**Reference:** `docs/superpowers/specs/2026-06-04-remote-approval-design.md`

**Run tests with:** `cd VibeBuddyKit && swift test` and `cd VibeBuddyMac && swift test`. iOS builds via `cd VibeBuddyApp && xcodegen generate && xcodebuild ...`.

---

## File structure

| File | Responsibility | Action |
|------|----------------|--------|
| `VibeBuddyKit/Sources/VibeBuddyKit/Models.swift` | add `PendingApproval` + `AgentSession.pendingApproval` | Modify |
| `VibeBuddyKit/Tests/VibeBuddyKitTests/WireCodingTests.swift` | Codable round-trip for pendingApproval | Modify |
| `VibeBuddyMac/Sources/VibeBuddyMacCore/PermissionMatcher.swift` | pure allow/deny/ask matcher + chaining guard | Create |
| `VibeBuddyMac/Sources/VibeBuddyMacCore/PermissionRules.swift` | load allow/deny from ~/.claude/settings.json | Create |
| `VibeBuddyMac/Sources/VibeBuddyMacCore/ApprovalRegistry.swift` | actor: hold/resolve/timeout pending approvals | Create |
| `VibeBuddyMac/Sources/VibeBuddyMacCore/SessionReducer.swift` | set/clear pendingApproval | Modify |
| `VibeBuddyMac/Sources/VibeBuddyMacCore/SessionStore.swift` | begin/end approval + broadcast | Modify |
| `VibeBuddyMac/Sources/VibeBuddyMacCore/VibeBuddyServer.swift` | `/approval` + `/decision` routes | Modify |
| `VibeBuddyMac/Tests/VibeBuddyMacCoreTests/*` | tests for each unit above | Create/Modify |
| `hooks/approval-hook.sh` | blocking forwarder | Create |
| `hooks/install-claude-hooks.py` | `--approval` opt-in flag | Modify |
| `VibeBuddyApp/Sources/DecisionClient.swift` | POST /decision | Create |
| `VibeBuddyApp/Sources/DashboardStore.swift` | `decide(_:approve:)` + keep pairing | Modify |
| `VibeBuddyApp/Sources/DashboardView.swift` | approve/deny buttons on a pendingApproval row | Modify |

---

## Task 1: Wire model — `PendingApproval`

**Files:**
- Modify: `VibeBuddyKit/Sources/VibeBuddyKit/Models.swift`
- Test: `VibeBuddyKit/Tests/VibeBuddyKitTests/WireCodingTests.swift`

- [ ] **Step 1: Write the failing test** — append inside the `WireCodingTests` suite:

```swift
@Test("AgentSession round-trips a pendingApproval")
func pendingApprovalRoundTrips() throws {
    var s = sampleSession(status: .needsResponse, waitKind: .permission)
    s.pendingApproval = PendingApproval(id: "ap1", tool: "Bash", commandPreview: "rm -rf build")
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(AgentSession.self, from: data)
    #expect(back.pendingApproval == s.pendingApproval)
    #expect(back.pendingApproval?.commandPreview == "rm -rf build")
}

@Test("pendingApproval defaults to nil and stays absent when unset")
func pendingApprovalDefaultsNil() {
    let s = sampleSession(status: .working)
    #expect(s.pendingApproval == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VibeBuddyKit && swift test --filter pendingApprovalRoundTrips`
Expected: FAIL — `PendingApproval` and `AgentSession.pendingApproval` don't exist (compile error), then assertion failure once the type is stubbed.

- [ ] **Step 3: Write minimal implementation** — in `Models.swift`, add the struct before `AgentSession`:

```swift
/// A tool use awaiting the user's approval from the phone. Present only while a
/// session is blocked on a remote approve/deny.
public struct PendingApproval: Codable, Sendable, Equatable {
    public let id: String
    public let tool: String
    public let commandPreview: String

    public init(id: String, tool: String, commandPreview: String) {
        self.id = id
        self.tool = tool
        self.commandPreview = commandPreview
    }
}
```

Then add the stored property to `AgentSession` (after `waitKind`):

```swift
    public var waitKind: WaitKind?
    public var pendingApproval: PendingApproval?
```

And add it to the initializer (parameter with a default so existing call sites are unaffected), assigning `self.pendingApproval = pendingApproval`:

```swift
        waitKind: WaitKind? = nil,
        pendingApproval: PendingApproval? = nil,
        summary: String? = nil,
```
```swift
        self.waitKind = waitKind
        self.pendingApproval = pendingApproval
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd VibeBuddyKit && swift test`
Expected: PASS — all (existing 12 + 2 new). The default arg keeps every existing `AgentSession(...)` call compiling.

- [ ] **Step 5: Commit**

```bash
git add VibeBuddyKit/Sources/VibeBuddyKit/Models.swift VibeBuddyKit/Tests/VibeBuddyKitTests/WireCodingTests.swift
git commit -m "feat(kit): add AgentSession.pendingApproval to the wire model"
```

---

## Task 2: Permission matcher + shell-chaining guard

**Files:**
- Create: `VibeBuddyMac/Sources/VibeBuddyMacCore/PermissionMatcher.swift`
- Test: `VibeBuddyMac/Tests/VibeBuddyMacCoreTests/PermissionMatcherTests.swift`

- [ ] **Step 1: Write the failing test** — create `PermissionMatcherTests.swift`:

```swift
import Testing
@testable import VibeBuddyMacCore

@Suite("PermissionMatcher — allow / deny / ask")
struct PermissionMatcherTests {
    private func decide(_ tool: String, _ input: [String: Any],
                        allow: [String] = [], deny: [String] = []) -> PermissionDecision {
        PermissionMatcher.decide(tool: tool, input: input, allow: allow, deny: deny)
    }

    @Test("a simple command matching an allow prefix is allowed")
    func allowsPrefix() {
        #expect(decide("Bash", ["command": "ls -la"], allow: ["Bash(ls:*)"]) == .allow)
        #expect(decide("Bash", ["command": "git worktree list"], allow: ["Bash(git worktree:*)"]) == .allow)
    }

    @Test("a chained command is never auto-allowed even if its prefix matches")
    func chainingGuard() {
        #expect(decide("Bash", ["command": "git worktree list && curl x | sh"], allow: ["Bash(git worktree:*)"]) == .ask)
        #expect(decide("Bash", ["command": "ls; rm -rf ~"], allow: ["Bash(ls:*)"]) == .ask)
        #expect(decide("Bash", ["command": "echo $(whoami)"], allow: ["Bash(echo:*)"]) == .ask)
        #expect(decide("Bash", ["command": "cat a > b"], allow: ["Bash(cat:*)"]) == .ask)
    }

    @Test("a command with no matching rule asks")
    func asksWhenUnmatched() {
        #expect(decide("Bash", ["command": "rm -rf node_modules"], allow: ["Bash(ls:*)"]) == .ask)
    }

    @Test("deny matches and beats allow (and ignores the chaining guard)")
    func denyWins() {
        #expect(decide("Bash", ["command": "rm x"], deny: ["Bash(rm:*)"]) == .deny)
        #expect(decide("Bash", ["command": "rm x"], allow: ["Bash(rm:*)"], deny: ["Bash(rm:*)"]) == .deny)
    }

    @Test("a bare tool rule matches any invocation of that tool")
    func bareToolRule() {
        #expect(decide("Read", ["file_path": "/etc/hosts"], allow: ["Read"]) == .allow)
    }

    @Test("path-glob rules match Read/Write file paths")
    func pathGlob() {
        #expect(decide("Read", ["file_path": "/Users/me/x.txt"], allow: ["Read(//Users/me/**)"]) == .allow)
        #expect(decide("Write", ["file_path": "/Users/me/src/a.swift"], allow: ["Write(//Users/me/src/**)"]) == .allow)
        #expect(decide("Write", ["file_path": "/etc/passwd"], allow: ["Write(//Users/me/**)"]) == .ask)
    }

    @Test("exact (no :*) Bash rule needs an exact command match")
    func exactBash() {
        #expect(decide("Bash", ["command": "make"], allow: ["Bash(make)"]) == .allow)
        #expect(decide("Bash", ["command": "make clean"], allow: ["Bash(make)"]) == .ask)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VibeBuddyMac && swift test --filter PermissionMatcher`
Expected: FAIL — `PermissionDecision` / `PermissionMatcher` don't exist.

- [ ] **Step 3: Write minimal implementation** — create `PermissionMatcher.swift`:

```swift
import Foundation

/// What to do with a tool use, derived purely from the permission rules.
public enum PermissionDecision: String, Sendable {
    case allow, deny, ask
}

/// Conservative replica of *just enough* of Claude Code's permission matching to
/// decide "silent vs ask": deny-list → .deny, allow-list → .allow, else .ask.
/// When unsure it returns .ask (over-asking is safe; under-asking is not).
public enum PermissionMatcher {

    /// Shell metacharacters that compose/redirect/background a command. A Bash
    /// command containing any of these is never auto-allowed.
    private static let composition: [String] = ["&&", "||", "|", ";", "$(", "`", ">", "<", "&", "\n"]

    public static func decide(
        tool: String, input: [String: Any], allow: [String], deny: [String]
    ) -> PermissionDecision {
        if deny.contains(where: { ruleMatches($0, tool: tool, input: input) }) { return .deny }
        if tool == "Bash", containsComposition(bashCommand(input)) { return .ask }
        if allow.contains(where: { ruleMatches($0, tool: tool, input: input) }) { return .allow }
        return .ask
    }

    static func containsComposition(_ command: String) -> Bool {
        composition.contains { command.contains($0) }
    }

    private static func bashCommand(_ input: [String: Any]) -> String {
        (input["command"] as? String) ?? ""
    }

    private static func filePath(_ input: [String: Any]) -> String {
        (input["file_path"] as? String) ?? ""
    }

    /// Parse `Tool(arg)` → (tool, arg); `Tool` → (tool, nil).
    static func parseRule(_ rule: String) -> (tool: String, arg: String?) {
        guard let open = rule.firstIndex(of: "("), rule.hasSuffix(")") else {
            return (rule, nil)
        }
        let tool = String(rule[rule.startIndex..<open])
        let arg = String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)])
        return (tool, arg)
    }

    private static func ruleMatches(_ rule: String, tool: String, input: [String: Any]) -> Bool {
        let parsed = parseRule(rule)
        guard parsed.tool == tool else { return false }
        guard let arg = parsed.arg else { return true }   // bare tool rule

        switch tool {
        case "Bash":
            let cmd = bashCommand(input).trimmingCharacters(in: .whitespaces)
            if arg.hasSuffix(":*") {
                let prefix = String(arg.dropLast(2))
                return cmd == prefix || cmd.hasPrefix(prefix + " ")
            }
            return cmd == arg
        case "Read", "Write", "Edit", "MultiEdit":
            return globMatches(arg, filePath(input))
        default:
            return false   // unknown tool with an arg pattern → conservative miss → .ask
        }
    }

    /// gitignore-ish glob: a leading `//` means absolute root, `**` matches any
    /// run (incl. `/`), `*` matches within a path segment.
    static func globMatches(_ pattern: String, _ path: String) -> Bool {
        var pat = pattern
        if pat.hasPrefix("//") { pat = String(pat.dropFirst()) }   // //abs → /abs
        let regex = "^" + pat
            .replacingOccurrences(of: "**", with: "\u{1}")          // placeholder
            .replacingOccurrences(of: "*", with: "[^/]*")
            .replacingOccurrences(of: "\u{1}", with: ".*") + "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd VibeBuddyMac && swift test --filter PermissionMatcher`
Expected: PASS — all 7 matcher tests.

- [ ] **Step 5: Commit**

```bash
git add VibeBuddyMac/Sources/VibeBuddyMacCore/PermissionMatcher.swift VibeBuddyMac/Tests/VibeBuddyMacCoreTests/PermissionMatcherTests.swift
git commit -m "feat(mac): conservative permission matcher with shell-chaining guard"
```

---

## Task 3: Permission rules loader

**Files:**
- Create: `VibeBuddyMac/Sources/VibeBuddyMacCore/PermissionRules.swift`
- Test: `VibeBuddyMac/Tests/VibeBuddyMacCoreTests/PermissionRulesTests.swift`

- [ ] **Step 1: Write the failing test** — create `PermissionRulesTests.swift`:

```swift
import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("PermissionRules — load allow/deny from settings.json")
struct PermissionRulesTests {
    @Test("loads allow and deny arrays from a settings file")
    func loadsArrays() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "vb-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"permissions":{"allow":["Bash(ls:*)","Read"],"deny":["Bash(rm:*)"]}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let rules = PermissionRules.load(settingsURL: url)
        #expect(rules.allow == ["Bash(ls:*)", "Read"])
        #expect(rules.deny == ["Bash(rm:*)"])
    }

    @Test("missing file yields empty rules (everything asks)")
    func missingFile() {
        let rules = PermissionRules.load(settingsURL: URL(fileURLWithPath: "/no/such/file.json"))
        #expect(rules.allow.isEmpty)
        #expect(rules.deny.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VibeBuddyMac && swift test --filter PermissionRules`
Expected: FAIL — `PermissionRules` doesn't exist.

- [ ] **Step 3: Write minimal implementation** — create `PermissionRules.swift`:

```swift
import Foundation

/// The allow/deny lists vibebuddy uses to decide silent-vs-ask. Read from the
/// user-level Claude Code settings; project-level merging is out of scope (its
/// absence only causes safe over-asking).
public struct PermissionRules: Sendable {
    public let allow: [String]
    public let deny: [String]

    public init(allow: [String], deny: [String]) {
        self.allow = allow
        self.deny = deny
    }

    public static func defaultSettingsURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    public static func load(settingsURL: URL = defaultSettingsURL()) -> PermissionRules {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let perms = obj["permissions"] as? [String: Any]
        else { return PermissionRules(allow: [], deny: []) }
        let allow = (perms["allow"] as? [String]) ?? []
        let deny = (perms["deny"] as? [String]) ?? []
        return PermissionRules(allow: allow, deny: deny)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd VibeBuddyMac && swift test --filter PermissionRules`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add VibeBuddyMac/Sources/VibeBuddyMacCore/PermissionRules.swift VibeBuddyMac/Tests/VibeBuddyMacCoreTests/PermissionRulesTests.swift
git commit -m "feat(mac): load allow/deny rules from ~/.claude/settings.json"
```

---

## Task 4: ApprovalRegistry actor (hold / resolve / timeout)

**Files:**
- Create: `VibeBuddyMac/Sources/VibeBuddyMacCore/ApprovalRegistry.swift`
- Test: `VibeBuddyMac/Tests/VibeBuddyMacCoreTests/ApprovalRegistryTests.swift`

- [ ] **Step 1: Write the failing test** — create `ApprovalRegistryTests.swift`:

```swift
import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("ApprovalRegistry — hold until decision or timeout")
struct ApprovalRegistryTests {
    @Test("resolve before timeout returns that outcome")
    func resolves() async {
        let reg = ApprovalRegistry()
        async let outcome = reg.wait(id: "a", timeout: .seconds(5))
        // give wait() a tick to register, then resolve
        try? await Task.sleep(for: .milliseconds(50))
        await reg.resolve(id: "a", with: .allow)
        #expect(await outcome == .allow)
    }

    @Test("no decision before the timeout yields .pass")
    func timesOut() async {
        let reg = ApprovalRegistry()
        let outcome = await reg.wait(id: "b", timeout: .milliseconds(50))
        #expect(outcome == .pass)
    }

    @Test("resolving an unknown id is a harmless no-op")
    func unknownResolve() async {
        let reg = ApprovalRegistry()
        await reg.resolve(id: "ghost", with: .deny)   // must not crash
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VibeBuddyMac && swift test --filter ApprovalRegistry`
Expected: FAIL — `ApprovalRegistry` doesn't exist.

- [ ] **Step 3: Write minimal implementation** — create `ApprovalRegistry.swift`:

```swift
import Foundation

/// Holds a blocking `/approval` request until the phone decides (`/decision`) or
/// the timeout fires. Each id is resumed exactly once — whichever of decision or
/// timeout arrives first wins; the other is a no-op.
public actor ApprovalRegistry {
    public enum Outcome: String, Sendable { case allow, deny, pass }

    private var waiters: [String: CheckedContinuation<Outcome, Never>] = [:]

    public init() {}

    public func wait(id: String, timeout: Duration) async -> Outcome {
        await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            waiters[id] = cont
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resume(id: id, with: .pass)
            }
        }
    }

    public func resolve(id: String, with outcome: Outcome) {
        resume(id: id, with: outcome)
    }

    private func resume(id: String, with outcome: Outcome) {
        guard let cont = waiters.removeValue(forKey: id) else { return }
        cont.resume(returning: outcome)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd VibeBuddyMac && swift test --filter ApprovalRegistry`
Expected: PASS — all 3 (the timeout test takes ~50ms).

- [ ] **Step 5: Commit**

```bash
git add VibeBuddyMac/Sources/VibeBuddyMacCore/ApprovalRegistry.swift VibeBuddyMac/Tests/VibeBuddyMacCoreTests/ApprovalRegistryTests.swift
git commit -m "feat(mac): ApprovalRegistry — hold a request until decision or timeout"
```

---

## Task 5: Reducer — set/clear pendingApproval

**Files:**
- Modify: `VibeBuddyMac/Sources/VibeBuddyMacCore/SessionReducer.swift`
- Test: `VibeBuddyMac/Tests/VibeBuddyMacCoreTests/SessionReducerTests.swift`

- [ ] **Step 1: Write the failing test** — append inside `SessionReducerTests`:

```swift
@Test("setPendingApproval marks the session needsResponse/permission with the approval")
func setsPendingApproval() {
    var r = SessionReducer()
    r.apply(ev(.sessionStart))
    r.setPendingApproval(sessionID: "s1",
                         PendingApproval(id: "ap1", tool: "Bash", commandPreview: "rm -rf x"),
                         at: t0.addingTimeInterval(1))
    let s = r.sessions["s1"]
    #expect(s?.status == .needsResponse)
    #expect(s?.waitKind == .permission)
    #expect(s?.pendingApproval?.id == "ap1")
}

@Test("clearPendingApproval drops the approval and returns the session to working")
func clearsPendingApproval() {
    var r = SessionReducer()
    r.apply(ev(.sessionStart))
    r.setPendingApproval(sessionID: "s1",
                         PendingApproval(id: "ap1", tool: "Bash", commandPreview: "x"),
                         at: t0.addingTimeInterval(1))
    r.clearPendingApproval(sessionID: "s1", at: t0.addingTimeInterval(2))
    let s = r.sessions["s1"]
    #expect(s?.pendingApproval == nil)
    #expect(s?.status == .working)
    #expect(s?.waitKind == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VibeBuddyMac && swift test --filter PendingApproval`
Expected: FAIL — `setPendingApproval`/`clearPendingApproval` don't exist.

- [ ] **Step 3: Write minimal implementation** — add to `SessionReducer` (after `enrich`):

```swift
/// Mark a known session as blocked on a remote approval.
public mutating func setPendingApproval(sessionID: String, _ approval: PendingApproval, at: Date) {
    guard var s = sessions[sessionID] else { return }
    if s.status != .needsResponse { s.statusSince = at }
    s.status = .needsResponse
    s.waitKind = .permission
    s.pendingApproval = approval
    s.updatedAt = at
    sessions[sessionID] = s
}

/// Clear a resolved/expired approval and return the session to working.
public mutating func clearPendingApproval(sessionID: String, at: Date) {
    guard var s = sessions[sessionID], s.pendingApproval != nil else { return }
    s.pendingApproval = nil
    s.waitKind = nil
    s.status = .working
    s.statusSince = at
    s.updatedAt = at
    sessions[sessionID] = s
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd VibeBuddyMac && swift test`
Expected: PASS — all (66 + 2 new).

- [ ] **Step 5: Commit**

```bash
git add VibeBuddyMac/Sources/VibeBuddyMacCore/SessionReducer.swift VibeBuddyMac/Tests/VibeBuddyMacCoreTests/SessionReducerTests.swift
git commit -m "feat(mac): reducer set/clear pendingApproval"
```

---

## Task 6: SessionStore — begin/end approval + broadcast

**Files:**
- Modify: `VibeBuddyMac/Sources/VibeBuddyMacCore/SessionStore.swift`
- Test: `VibeBuddyMac/Tests/VibeBuddyMacCoreTests/SessionStoreTests.swift`

- [ ] **Step 1: Write the failing test** — append inside `SessionStoreTests`:

```swift
@Test("beginApproval makes the session needsResponse with a pendingApproval; endApproval clears it")
func approvalLifecycle() async {
    let store = SessionStore()
    await store.ingest(
        Data(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/proj"}"#.utf8),
        receivedAt: t0)

    await store.beginApproval(sessionID: "s",
                              PendingApproval(id: "ap1", tool: "Bash", commandPreview: "rm x"),
                              at: t0.addingTimeInterval(1))
    let waiting = await store.snapshot(now: t0).sessions.first
    #expect(waiting?.status == .needsResponse)
    #expect(waiting?.pendingApproval?.id == "ap1")

    await store.endApproval(sessionID: "s", at: t0.addingTimeInterval(2))
    let done = await store.snapshot(now: t0).sessions.first
    #expect(done?.pendingApproval == nil)
    #expect(done?.status == .working)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VibeBuddyMac && swift test --filter approvalLifecycle`
Expected: FAIL — `beginApproval`/`endApproval` don't exist on the actor.

- [ ] **Step 3: Write minimal implementation** — add to `SessionStore` (after `ingest`):

```swift
public func beginApproval(sessionID: String, _ approval: PendingApproval, at: Date) {
    reducer.setPendingApproval(sessionID: sessionID, approval, at: at)
    broadcast()
}

public func endApproval(sessionID: String, at: Date) {
    reducer.clearPendingApproval(sessionID: sessionID, at: at)
    broadcast()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd VibeBuddyMac && swift test --filter approvalLifecycle`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add VibeBuddyMac/Sources/VibeBuddyMacCore/SessionStore.swift VibeBuddyMac/Tests/VibeBuddyMacCoreTests/SessionStoreTests.swift
git commit -m "feat(mac): SessionStore begin/end approval"
```

---

## Task 7: Daemon routes — `/approval` (blocking) + `/decision` (token-gated)

**Files:**
- Modify: `VibeBuddyMac/Sources/VibeBuddyMacCore/VibeBuddyServer.swift`
- Test: `VibeBuddyMac/Tests/VibeBuddyMacCoreTests/ApprovalRoutesTests.swift`

- [ ] **Step 1: Write the failing test** — create `ApprovalRoutesTests.swift`:

```swift
import Testing
import Foundation
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Approval routes")
struct ApprovalRoutesTests {
    private func server(allow: [String] = [], deny: [String] = []) -> VibeBuddyServer {
        VibeBuddyServer(store: SessionStore(), token: "t0k",
                        approvalRegistry: ApprovalRegistry(),
                        rules: { PermissionRules(allow: allow, deny: deny) },
                        approvalTimeout: .milliseconds(200))
    }

    @Test("allow-listed command returns an allow decision immediately")
    func allowImmediate() async throws {
        let body = #"{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls -la"}}"#
        try await server(allow: ["Bash(ls:*)"]).buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval", method: .post, body: ByteBuffer(string: body)) { res in
                #expect(res.status == .ok)
                let text = String(buffer: res.body)
                #expect(text.contains("\"permissionDecision\":\"allow\""))
            }
        }
    }

    @Test("an un-listed command holds, then a /decision approve releases it")
    func askThenApprove() async throws {
        let body = #"{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
        let srv = server()   // empty allow → .ask
        try await srv.buildApplication().test(.router) { client in
            // Fire the blocking /approval and a /decision concurrently.
            async let approval = client.execute(uri: "/approval", method: .post, body: ByteBuffer(string: body)) { res -> String in
                #expect(res.status == .ok)
                return String(buffer: res.body)
            }
            // Let /approval register the pending entry, then approve it.
            try await Task.sleep(for: .milliseconds(80))
            let decision = #"{"approvalId":"s","decision":"allow"}"#
            try await client.execute(uri: "/decision", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: decision)) { res in
                #expect(res.status == .ok)
            }
            let text = try await approval
            #expect(text.contains("\"permissionDecision\":\"allow\""))
        }
    }

    @Test("no decision times out to an empty body (hook prints nothing)")
    func timesOutEmpty() async throws {
        let body = #"{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
        try await server().buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval", method: .post, body: ByteBuffer(string: body)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).isEmpty)   // 200ms timeout → empty
            }
        }
    }

    @Test("/decision without a token is 401")
    func decisionUnauthorized() async throws {
        try await server().buildApplication().test(.router) { client in
            try await client.execute(uri: "/decision", method: .post,
                                     body: ByteBuffer(string: #"{"approvalId":"x","decision":"allow"}"#)) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
```

> Note: the test uses `session_id` as the `approvalId` for simplicity. In production the approvalId is a fresh UUID (Step 3); the daemon stores `pendingApproval.id` on the session so the phone echoes it back. The test injects a known id by having the daemon use the session id when no UUID source is supplied — see Step 3's `approvalID` closure (defaults to `UUID().uuidString`, overridden in tests).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd VibeBuddyMac && swift test --filter ApprovalRoutes`
Expected: FAIL — the new `VibeBuddyServer` init params and routes don't exist.

- [ ] **Step 3: Write minimal implementation**

In `VibeBuddyServer.swift`, add stored properties and extend `init` (keep the existing init working by giving defaults):

```swift
    public let approvalRegistry: ApprovalRegistry
    public let rules: @Sendable () -> PermissionRules
    public let approvalTimeout: Duration
    public let approvalID: @Sendable () -> String

    public init(store: SessionStore, token: String, host: String = "0.0.0.0",
                port: Int = 9876, pusher: APNsPusher? = nil,
                approvalRegistry: ApprovalRegistry = ApprovalRegistry(),
                rules: @escaping @Sendable () -> PermissionRules = { PermissionRules.load() },
                approvalTimeout: Duration = .seconds(25),
                approvalID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.store = store
        self.token = token
        self.host = host
        self.port = port
        self.pusher = pusher
        self.approvalRegistry = approvalRegistry
        self.rules = rules
        self.approvalTimeout = approvalTimeout
        self.approvalID = approvalID
    }
```

> For deterministic tests, the test `server(...)` helper passes `approvalID: { "s" }`? No — to keep the test's `approvalId == session_id`, add this to the test helper's init call: `approvalID: { "s" }`. Update the Step-1 helper to include `approvalID: { "s" }` so the pending id equals the session id used by `/decision`.

Add the two routes inside `router()` (before `return router`):

```swift
        // Blocking approval intake (localhost). Mirrors a genuine Mac prompt:
        // allow-listed → allow, deny-listed → deny, else hold for the phone.
        let registry = self.approvalRegistry
        let rules = self.rules
        let timeout = self.approvalTimeout
        let makeID = self.approvalID
        router.post("approval") { request, _ -> Response in
            let buffer = try await request.body.collect(upTo: 1 << 20)
            let data = Data(buffer: buffer)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let tool = obj["tool_name"] as? String ?? ""
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            let sessionID = obj["session_id"] as? String ?? ""
            let r = rules()
            let decision = PermissionMatcher.decide(tool: tool, input: input, allow: r.allow, deny: r.deny)

            // Keep the working-status update the /hook PreToolUse used to do.
            await store.ingest(data, receivedAt: Date())

            switch decision {
            case .allow: return Self.permissionResponse("allow")
            case .deny:  return Self.permissionResponse("deny")
            case .ask:
                let id = makeID()
                let preview = Self.preview(tool: tool, input: input)
                await store.beginApproval(sessionID: sessionID,
                    PendingApproval(id: id, tool: tool, commandPreview: preview), at: Date())
                let outcome = await registry.wait(id: id, timeout: timeout)
                await store.endApproval(sessionID: sessionID, at: Date())
                switch outcome {
                case .allow: return Self.permissionResponse("allow")
                case .deny:  return Self.permissionResponse("deny")
                case .pass:  return Response(status: .ok)   // empty → hook prints nothing
                }
            }
        }

        // Phone → decision. Token-gated.
        router.post("decision") { request, _ -> HTTPResponse.Status in
            guard request.headers[.authorization] == "Bearer \(token)" else { throw HTTPError(.unauthorized) }
            let buffer = try await request.body.collect(upTo: 4096)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any],
                  let id = obj["approvalId"] as? String,
                  let decision = obj["decision"] as? String
            else { throw HTTPError(.badRequest) }
            await registry.resolve(id: id, with: decision == "allow" ? .allow : .deny)
            return .ok
        }
```

Add these helpers to `VibeBuddyServer` (after `router()`):

```swift
    static func permissionResponse(_ decision: String) -> Response {
        let json = #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"\#(decision)","permissionDecisionReason":"vibebuddy"}}"#
        return Response(status: .ok,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: json)))
    }

    static func preview(tool: String, input: [String: Any]) -> String {
        let raw: String
        if let cmd = input["command"] as? String { raw = cmd }
        else if let path = input["file_path"] as? String { raw = path }
        else { raw = tool }
        return String(raw.prefix(120))
    }
```

Update the Step-1 test helper to pass `approvalID: { "s" }`:

```swift
    private func server(allow: [String] = [], deny: [String] = []) -> VibeBuddyServer {
        VibeBuddyServer(store: SessionStore(), token: "t0k",
                        approvalRegistry: ApprovalRegistry(),
                        rules: { PermissionRules(allow: allow, deny: deny) },
                        approvalTimeout: .milliseconds(200),
                        approvalID: { "s" })
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd VibeBuddyMac && swift test`
Expected: PASS — all suites including the 4 approval-route tests. (The `askThenApprove` test relies on `approvalID: { "s" }` so the `/decision` `approvalId:"s"` matches.)

- [ ] **Step 5: Commit**

```bash
git add VibeBuddyMac/Sources/VibeBuddyMacCore/VibeBuddyServer.swift VibeBuddyMac/Tests/VibeBuddyMacCoreTests/ApprovalRoutesTests.swift
git commit -m "feat(mac): /approval (blocking) and /decision (token-gated) routes"
```

---

## Task 8: Blocking hook script + opt-in installer flag

**Files:**
- Create: `hooks/approval-hook.sh`
- Modify: `hooks/install-claude-hooks.py`
- Test (manual): described below

- [ ] **Step 1: Create the hook script** `hooks/approval-hook.sh`:

```sh
#!/usr/bin/env bash
# Blocking PreToolUse approval forwarder. Reads the hook JSON on stdin, asks the
# local daemon, and echoes its permission decision. On any failure it prints
# nothing and exits 0 so Claude Code proceeds with its normal flow.
PORT="${VIBEBUDDY_PORT:-9876}"
RESP=$(curl -sS --max-time 30 -X POST --data-binary @- "http://127.0.0.1:${PORT}/approval" 2>/dev/null)
[ -n "$RESP" ] && printf '%s' "$RESP"
exit 0
```

Then: `chmod +x hooks/approval-hook.sh`

- [ ] **Step 2: Add the opt-in flag to `install-claude-hooks.py`**

Add near the top (after `COMMAND`):

```python
APPROVAL_HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "approval-hook.sh")
APPROVAL_COMMAND = f'"{APPROVAL_HOOK}"'
APPROVAL_MARKER = "approval-hook.sh"
```

Add an installer for the approval hook (replaces PreToolUse's `/hook` group with the blocking one):

```python
def install_approval(data):
    hooks = data.setdefault("hooks", {})
    arr = hooks.setdefault("PreToolUse", [])
    # Drop the fire-and-forget vibebuddy /hook group for PreToolUse; the blocking
    # approval hook subsumes the working-status update via /approval.
    arr[:] = [g for g in arr if not is_vibebuddy(g)]
    if not any(APPROVAL_MARKER in h.get("command", "")
               for g in arr if isinstance(g, dict)
               for h in g.get("hooks", []) if isinstance(h, dict)):
        arr.append({"matcher": "*", "hooks": [{"type": "command", "command": APPROVAL_COMMAND}]})
    return ["PreToolUse(approval)"]
```

Wire it into `main()`:

```python
    if mode == "--approval":
        install(data)              # ensure base status hooks exist
        added = install_approval(data)
        write(data)
        print("installed vibebuddy approval hook:", added)
        return
```

And teach `uninstall` to also strip the approval hook — change `is_vibebuddy` to also recognise the approval marker:

```python
def is_vibebuddy(g):
    return isinstance(g, dict) and any(
        (MARKER in h.get("command", "") or APPROVAL_MARKER in h.get("command", ""))
        for h in g.get("hooks", []) if isinstance(h, dict)
    )
```

- [ ] **Step 3: Verify the installer (dry run, no write)**

Run:
```bash
python3 - <<'PY'
import json, sys
sys.argv = ["x"]
import importlib.util
spec = importlib.util.spec_from_file_location("ih", "hooks/install-claude-hooks.py")
ih = importlib.util.module_from_spec(spec); spec.loader.exec_module(ih)
data = {"hooks": {"PreToolUse": [{"matcher": "*", "hooks": [{"type":"command","command": ih.COMMAND}]}]}}
print("before:", json.dumps(data["hooks"]["PreToolUse"]))
print("added:", ih.install_approval(data))
print("after:", json.dumps(data["hooks"]["PreToolUse"]))
assert any("approval-hook.sh" in h["command"] for g in data["hooks"]["PreToolUse"] for h in g["hooks"])
assert not any(ih.MARKER in h["command"] for g in data["hooks"]["PreToolUse"] for h in g["hooks"])
print("OK: /hook PreToolUse replaced by blocking approval hook")
PY
```
Expected: prints `OK: …` (the blocking hook replaced the fire-and-forget one for PreToolUse).

- [ ] **Step 4: Update `hooks/README.md`** — add a short "Remote approval (opt-in)" section:

```markdown
## Remote approval (opt-in)

```bash
python3 hooks/install-claude-hooks.py --approval   # add the blocking PreToolUse approval hook
python3 hooks/install-claude-hooks.py --uninstall  # removes it too
```
Commands not in your `permissions.allow` are sent to the phone to approve/deny.
On timeout/unreachable, Claude proceeds with its normal behaviour. Useful only if
your Mac actually prompts (prompting mode); auto-mode users gain nothing.
```

- [ ] **Step 5: Commit**

```bash
git add hooks/approval-hook.sh hooks/install-claude-hooks.py hooks/README.md
git commit -m "feat(hooks): opt-in blocking approval hook + installer flag"
```

---

## Task 9: iOS — decision client, store wiring, approve/deny UI

**Files:**
- Create: `VibeBuddyApp/Sources/DecisionClient.swift`
- Modify: `VibeBuddyApp/Sources/DashboardStore.swift`
- Modify: `VibeBuddyApp/Sources/DashboardView.swift`

> iOS app code is built via xcodegen + xcodebuild and verified in the Simulator/live (no SwiftPM test target). Keep each piece small and compile-check after each.

- [ ] **Step 1: Create `DecisionClient.swift`**

```swift
import Foundation
import VibeBuddyKit

/// POSTs an approve/deny decision back to the Mac. Best-effort: failures are
/// swallowed (the daemon will time out and fall back).
protocol DecisionClient: Sendable {
    func decide(_ pairing: PairingPayload, approvalId: String, approve: Bool) async
}

struct HTTPDecisionClient: DecisionClient {
    func decide(_ pairing: PairingPayload, approvalId: String, approve: Bool) async {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/decision") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["approvalId": approvalId, "decision": approve ? "allow" : "deny"]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}
```

- [ ] **Step 2: Wire it into `DashboardStore`**

Add the dependency + a stored pairing, and a `decide` method. Modify the init and `start`:

```swift
    private let decisionClient: DecisionClient
    private var pairing: PairingPayload?

    init(streamer: SnapshotStreaming = WebSocketSnapshotClient(),
         notifier: AttentionNotifier = LocalNotifier(),
         decisionClient: DecisionClient = HTTPDecisionClient()) {
        self.streamer = streamer
        self.notifier = notifier
        self.decisionClient = decisionClient
        notifier.requestAuthorization()
    }
```

In `start(_ pairing:)`, store it: add `self.pairing = pairing` at the top of the method (after `stop()`).

Add the method:

```swift
    func decide(_ approvalId: String, approve: Bool) {
        guard let pairing else { return }
        Task { await decisionClient.decide(pairing, approvalId: approvalId, approve: approve) }
    }
```

- [ ] **Step 3: Add approve/deny buttons to the row in `DashboardView.swift`**

In `SessionRow`, add an environment ref and render buttons when `pendingApproval != nil`. At the top of `SessionRow`:

```swift
    @EnvironmentObject private var dashboard: DashboardStore
```

Append, inside the inner `VStack(alignment: .leading)` after the metadata `HStack`:

```swift
                if let approval = session.pendingApproval {
                    HStack(spacing: 10) {
                        Button("拒绝") { dashboard.decide(approval.id, approve: false) }
                            .buttonStyle(.bordered).tint(.red)
                        Button("批准") { dashboard.decide(approval.id, approve: true) }
                            .buttonStyle(.borderedProminent).tint(.green)
                    }
                    .font(.subheadline)
                    .padding(.top, 4)
                }
```

(The command itself is already shown via `session.summary`/`commandPreview`; if you want the preview explicitly, render `Text(approval.commandPreview).font(.caption.monospaced())` above the buttons.)

- [ ] **Step 4: Build the app**

Run:
```bash
cd VibeBuddyApp && xcodegen generate && xcodebuild -project VibeBuddyApp.xcodeproj -scheme VibeBuddyApp -configuration Debug -sdk iphonesimulator -derivedDataPath build build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add VibeBuddyApp/Sources/DecisionClient.swift VibeBuddyApp/Sources/DashboardStore.swift VibeBuddyApp/Sources/DashboardView.swift
git commit -m "feat(ios): approve/deny buttons + POST /decision"
```

---

## Task 10: End-to-end verification (live)

- [ ] **Step 1** — Rebuild & redeploy the menu-bar app (no Keychain prompt now):
```bash
cd VibeBuddyMacApp && xcodegen generate && xcodebuild -project VibeBuddyMacApp.xcodeproj -scheme VibeBuddyMacApp -configuration Release -derivedDataPath build build
osascript -e 'tell application "VibeBuddyMacApp" to quit'; sleep 2; pkill -x VibeBuddyMacApp
rm -rf /Applications/VibeBuddyMacApp.app && ditto VibeBuddyMacApp/build/Build/Products/Release/VibeBuddyMacApp.app /Applications/VibeBuddyMacApp.app
open /Applications/VibeBuddyMacApp.app
```
- [ ] **Step 2** — Enable the opt-in hook: `python3 hooks/install-claude-hooks.py --approval`
- [ ] **Step 3** — Simulate a non-allow command against the live daemon and confirm it holds then a decision releases it:
```bash
TOKEN=$(cat "$HOME/Library/Application Support/vibebuddy/token")
# In one shell: fire a blocking approval (will hang ~ up to 25s)
( printf '%s' '{"hook_event_name":"PreToolUse","session_id":"verify-ap","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' \
  | curl -sS --max-time 30 -X POST --data-binary @- http://127.0.0.1:9876/approval ) &
sleep 1
# Confirm the session shows pendingApproval in the snapshot:
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9876/snapshot | python3 -c 'import sys,json;[print(s["project"], s.get("pendingApproval")) for s in json.load(sys.stdin)["sessions"]]'
# Approve it:
curl -sS -X POST -H "Authorization: Bearer $TOKEN" --data-binary '{"approvalId":"<id-from-snapshot>","decision":"allow"}' http://127.0.0.1:9876/decision
wait   # the backgrounded /approval should now return the allow JSON
```
Expected: the snapshot shows a `pendingApproval`; after `/decision`, the held `/approval` returns `{"hookSpecificOutput":{..."permissionDecision":"allow"...}}`.
- [ ] **Step 4** — On the phone (real device or Simulator paired to the Mac), repeat: run a non-allow command on the Mac, see the row show 批准/拒绝, tap 批准, confirm the command runs.
- [ ] **Step 5** — Confirm the timeout path: fire `/approval`, don't decide; after ~25s it returns an empty body (Claude would proceed normally). Note (per spec): the "timeout → terminal prompt" branch can't be exercised on the auto-mode dev Mac.

---

## Self-review notes
- **Spec coverage:** wire model (T1), matcher + chaining guard (T2), rules loader (T3), pending registry/timeout (T4), reducer (T5), store (T6), `/approval`+`/decision` (T7), opt-in hook+installer (T8), iOS approve/deny (T9), live verify incl. honest timeout caveat (T10). All spec sections mapped.
- **Type consistency:** `PendingApproval(id:tool:commandPreview:)`, `PermissionDecision{allow,deny,ask}`, `ApprovalRegistry.Outcome{allow,deny,pass}`, `PermissionRules(allow:deny:)` used identically across tasks. `/approval` correlates via `pendingApproval.id`; `/decision` sends `approvalId`.
- **Known caveat:** auto-mode dev Mac cannot exercise the timeout→terminal-prompt fallback (covered by reasoning + unit tests).
