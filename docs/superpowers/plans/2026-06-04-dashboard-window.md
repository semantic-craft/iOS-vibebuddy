# Dashboard Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A macOS window in the menu-bar app to browse all sessions, select with the keyboard, and approve/deny on the Mac — opened via a global hotkey (⌃⌥⇧⌘') or the menu.

**Architecture:** New SwiftUI `Window` scene + `NavigationSplitView` (sidebar status/agent filter · session list · detail) bound to the existing in-process `MenuBarModel`/`SessionStore` (no networking). Mac-side approve/deny reuses the already-built `ApprovalRegistry` by having `MenuBarModel` own+share it. Global hotkey via Carbon `RegisterEventHotKey`.

**Tech Stack:** SwiftUI + AppKit (macOS 14), Swift 6, xcodegen, Swift Testing (for the one pure helper).

**Reference spec:** `docs/superpowers/specs/2026-06-04-dashboard-window-design.md`

**Most code lives in the app target `VibeBuddyMacApp/` (built with `xcodebuild`, no unit-test target) — so tasks 2–6 are verified by a clean Release build; task 1 is TDD in `VibeBuddyKit`.**

**App build command (used to verify tasks 2–6):**
```bash
cd <path-to-iOS-vibebuddy>/VibeBuddyMacApp && xcodegen generate && \
xcodebuild -project VibeBuddyMacApp.xcodeproj -scheme VibeBuddyMacApp -configuration Release -derivedDataPath build build 2>&1 | grep -Ei "error:|BUILD SUCCEEDED|BUILD FAILED" | tail
```
Always run `xcodegen generate` after adding a new source file (the `.xcodeproj` globs `Sources/`).

---

## File structure

| File | Responsibility | Action |
|------|----------------|--------|
| `VibeBuddyKit/Sources/VibeBuddyKit/SessionFilter.swift` | pure status/agent/query filter | Create |
| `VibeBuddyKit/Tests/VibeBuddyKitTests/SessionFilterTests.swift` | filter tests | Create |
| `VibeBuddyMacApp/Sources/MenuBarModel.swift` | own+share `ApprovalRegistry`; `decide()`; expose `pendingApprovalCount` | Modify |
| `VibeBuddyMacApp/Sources/DashboardView.swift` | the 3-pane window UI | Create |
| `VibeBuddyMacApp/Sources/GlobalHotkey.swift` | Carbon hotkey → callback | Create |
| `VibeBuddyMacApp/Sources/VibeBuddyMenuBarApp.swift` | `Window` scene + menu "打开 Dashboard" + hotkey wiring | Modify |

---

## Task 1: Pure session filter (TDD)

**Files:**
- Create: `VibeBuddyKit/Sources/VibeBuddyKit/SessionFilter.swift`
- Test: `VibeBuddyKit/Tests/VibeBuddyKitTests/SessionFilterTests.swift`

- [ ] **Step 1: Failing test** — create `SessionFilterTests.swift`:

```swift
import Testing
import Foundation
import VibeBuddyKit

@Suite("SessionFilter")
struct SessionFilterTests {
    private func s(_ id: String, _ status: SessionStatus, agent: AgentKind = .claudeCode,
                   project: String = "proj", summary: String? = nil) -> AgentSession {
        AgentSession(id: id, agent: agent, project: project, status: status,
                     summary: summary, statusSince: Date(timeIntervalSince1970: 0),
                     updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("status filter keeps only that status")
    func byStatus() {
        let all = [s("a", .needsResponse), s("b", .working), s("c", .done)]
        let r = SessionFilter.apply(all, status: .working, agent: nil, query: "")
        #expect(r.map(\.id) == ["b"])
    }

    @Test("agent filter keeps only that agent")
    func byAgent() {
        let all = [s("a", .working, agent: .claudeCode), s("b", .working, agent: .codex)]
        #expect(SessionFilter.apply(all, status: nil, agent: .codex, query: "").map(\.id) == ["b"])
    }

    @Test("query matches project or summary, case-insensitively")
    func byQuery() {
        let all = [s("a", .working, project: "iOS-vibebuddy"),
                   s("b", .working, project: "other", summary: "fix the BUG")]
        #expect(SessionFilter.apply(all, status: nil, agent: nil, query: "vibe").map(\.id) == ["a"])
        #expect(SessionFilter.apply(all, status: nil, agent: nil, query: "bug").map(\.id) == ["b"])
    }

    @Test("nil filters + empty query return everything")
    func noFilter() {
        let all = [s("a", .working), s("b", .done)]
        #expect(SessionFilter.apply(all, status: nil, agent: nil, query: "").count == 2)
    }

    @Test("presentAgents lists distinct agents that appear")
    func present() {
        let all = [s("a", .working, agent: .claudeCode), s("b", .done, agent: .codex), s("c", .working, agent: .claudeCode)]
        #expect(Set(SessionFilter.presentAgents(all)) == Set([.claudeCode, .codex]))
    }
}
```

- [ ] **Step 2: Run → fail** — `cd VibeBuddyKit && swift test --filter SessionFilter` → FAIL (`SessionFilter` missing).

- [ ] **Step 3: Implement** — create `SessionFilter.swift`:

```swift
import Foundation

/// Pure filtering for the dashboard: by status, by agent, and a text query over
/// project/summary. nil status/agent = no filter; empty query = match all.
public enum SessionFilter {
    public static func apply(_ sessions: [AgentSession], status: SessionStatus?,
                             agent: AgentKind?, query: String) -> [AgentSession] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return sessions.filter { s in
            if let status, s.status != status { return false }
            if let agent, s.agent != agent { return false }
            if !q.isEmpty {
                let hay = (s.project + " " + (s.summary ?? "")).lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    /// Distinct agents present in the snapshot, in stable CaseIterable order.
    public static func presentAgents(_ sessions: [AgentSession]) -> [AgentKind] {
        let present = Set(sessions.map(\.agent))
        return AgentKind.allCases.filter { present.contains($0) }
    }
}
```

- [ ] **Step 4: Run → pass** — `cd VibeBuddyKit && swift test` → all pass (14 + 5 new). Paste summary.

- [ ] **Step 5: Commit**
```bash
git add VibeBuddyKit/Sources/VibeBuddyKit/SessionFilter.swift VibeBuddyKit/Tests/VibeBuddyKitTests/SessionFilterTests.swift
git commit -m "feat(kit): pure SessionFilter for the dashboard (status/agent/query)"
```

---

## Task 2: MenuBarModel — own & share the ApprovalRegistry, add decide()

**Files:** Modify `VibeBuddyMacApp/Sources/MenuBarModel.swift`

Currently `MenuBarModel.startServer()` does `VibeBuddyServer(store: store, token: token, port: port, pusher: pusher)` (registry defaults to a fresh internal one the app can't reach). Change it to own the registry and pass it in, and expose `decide`.

- [ ] **Step 1: Implement** — add a stored registry and method:

In the stored properties:
```swift
    private let approvalRegistry = ApprovalRegistry()
```
In `startServer()`, pass it:
```swift
        let server = VibeBuddyServer(store: store, token: token, port: port,
                                     pusher: pusher, approvalRegistry: approvalRegistry)
```
Add the method (resolve a pending approval locally — same effect as the phone):
```swift
    /// Resolve a pending approval from the Mac (Dashboard buttons / shortcuts).
    func decide(_ approvalId: String, approve: Bool) {
        Task { await approvalRegistry.resolve(id: approvalId, with: approve ? .allow : .deny) }
    }
```
`ApprovalRegistry` is in `VibeBuddyMacCore` (already imported by this file).

- [ ] **Step 2: Build to verify** — run the app build command (top of plan). Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**
```bash
git add VibeBuddyMacApp/Sources/MenuBarModel.swift
git commit -m "feat(mac): MenuBarModel owns/shares the ApprovalRegistry + decide()"
```

---

## Task 3: DashboardView (3-pane NavigationSplitView)

**Files:** Create `VibeBuddyMacApp/Sources/DashboardView.swift`

- [ ] **Step 1: Implement** — create `DashboardView.swift`. It binds to the shared `MenuBarModel` and uses `SessionFilter`. Keyboard ↑/↓ comes free from `List(selection:)`.

```swift
import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct DashboardView: View {
    @ObservedObject var model: MenuBarModel
    @State private var statusFilter: SessionStatus? = .needsResponse
    @State private var agentFilter: AgentKind? = nil
    @State private var query: String = ""
    @State private var selection: String? = nil

    private var filtered: [AgentSession] {
        let f = SessionFilter.apply(model.sessions, status: statusFilter, agent: agentFilter, query: query)
        return f.sorted {
            $0.status.attentionRank != $1.status.attentionRank
                ? $0.status.attentionRank < $1.status.attentionRank
                : $0.updatedAt > $1.updatedAt
        }
    }
    private var selectedSession: AgentSession? { model.sessions.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            List(filtered, selection: $selection) { s in
                SessionRowView(session: s).tag(s.id)
            }
            .searchable(text: $query, prompt: "搜索会话")
            .navigationTitle("vibebuddy")
        } detail: {
            if let s = selectedSession { DetailView(session: s, model: model) }
            else { ContentUnavailableView("选择一个会话", systemImage: "sidebar.right") }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { statusFilter }, set: { statusFilter = $0 })) {
            Section("状态") {
                statusItem(.needsResponse, "需回应", .orange)
                statusItem(.working, "进行中", .blue)
                statusItem(.done, "已完成", .green)
            }
            Section("Agent") {
                ForEach(SessionFilter.presentAgents(model.sessions), id: \.self) { a in
                    Button {
                        agentFilter = (agentFilter == a) ? nil : a
                    } label: {
                        HStack {
                            Text(a == .claudeCode ? "Claude Code" : "Codex")
                            Spacer()
                            if agentFilter == a { Image(systemName: "checkmark") }
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func statusItem(_ status: SessionStatus, _ label: String, _ color: Color) -> some View {
        let count = model.sessions.filter { $0.status == status }.count
        return HStack {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }.tag(Optional(status))
    }
}

private struct SessionRowView: View {
    let session: AgentSession
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(session.project).fontWeight(.semibold)
            }
            if let s = session.summary { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Text(session.agent == .claudeCode ? "Claude Code" : "Codex")
                .font(.caption2).foregroundStyle(.tertiary)
        }.padding(.vertical, 2)
    }
    private var color: Color {
        switch session.status { case .needsResponse: .orange; case .working: .blue; case .done: .green }
    }
}

private struct DetailView: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(session.project).font(.title2.bold())
                if let approval = session.pendingApproval {
                    Text("Claude 想执行,需要你批准:").font(.headline)
                    Text(approval.commandPreview).font(.system(.body, design: .monospaced))
                        .padding(10).background(Color(nsColor: .textBackgroundColor)).cornerRadius(8)
                    HStack(spacing: 10) {
                        Button("批准") { model.decide(approval.id, approve: true) }
                            .keyboardShortcut("a", modifiers: []).tint(.green)
                        Button("拒绝") { model.decide(approval.id, approve: false) }
                            .keyboardShortcut("d", modifiers: []).tint(.red)
                        Button("跳回终端") { }.disabled(true)   // STUB — sub-project 2
                    }.buttonStyle(.borderedProminent)
                } else {
                    if let s = session.summary { Text(s).foregroundStyle(.secondary) }
                    Button("跳回终端") { }.disabled(true)   // STUB — sub-project 2
                }
                if let model = session.model { Label(model, systemImage: "cpu") .font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

- [ ] **Step 2: Build to verify** — `xcodegen generate` (new file!) then the app build command. Fix any compile error minimally (e.g. `ContentUnavailableView` availability on macOS 14 is fine; `Circle().fill` in a `switch` expression needs the right syntax). Expected `** BUILD SUCCEEDED **`. (The view isn't shown yet — that's Task 4 — this step only confirms it compiles.)

- [ ] **Step 3: Commit**
```bash
git add VibeBuddyMacApp/Sources/DashboardView.swift
git commit -m "feat(mac): dashboard 3-pane NavigationSplitView (browse/select/approve)"
```

---

## Task 4: Window scene + menu entry

**Files:** Modify `VibeBuddyMacApp/Sources/VibeBuddyMenuBarApp.swift`

- [ ] **Step 1: Implement** — add a `Window` scene and a menu button to open it.

In `VibeBuddyMenuBarApp.body` (a `Scene`), after the `MenuBarExtra { ... }`:
```swift
        Window("vibebuddy", id: "dashboard") {
            DashboardView(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
```
In `MenuContent` (the menu-bar popover), add a button near the top that opens the window:
```swift
    @Environment(\.openWindow) private var openWindow
```
and a button:
```swift
            Button("打开 Dashboard") {
                NSApp.setActivationPolicy(.regular)   // show in dock/⌘-tab while window is open
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderless)
```

- [ ] **Step 2: Build + quick run check** — app build command → `** BUILD SUCCEEDED **`. (Optional manual: run the app, click "打开 Dashboard", confirm the 3-pane window appears with live sessions.)

- [ ] **Step 3: Commit**
```bash
git add VibeBuddyMacApp/Sources/VibeBuddyMenuBarApp.swift
git commit -m "feat(mac): dashboard Window scene + menu entry"
```

---

## Task 5: Global hotkey (⌃⌥⇧⌘') via Carbon

**Files:** Create `VibeBuddyMacApp/Sources/GlobalHotkey.swift`; wire in `VibeBuddyMenuBarApp.swift`.

- [ ] **Step 1: Implement** — create `GlobalHotkey.swift` (self-contained Carbon registration, no dependency, no Accessibility prompt):

```swift
import Carbon.HIToolbox
import AppKit

/// Registers a single system-wide hotkey and calls `handler` when pressed.
/// Default ⌃⌥⇧⌘ + ' (kVK_ANSI_Quote). No Accessibility permission needed.
final class GlobalHotkey {
    private var ref: EventHotKeyRef?
    private let handler: () -> Void
    private static var shared: GlobalHotkey?

    init(keyCode: UInt32 = UInt32(kVK_ANSI_Quote),
         modifiers: UInt32 = UInt32(cmdKey | optionKey | shiftKey | controlKey),
         handler: @escaping () -> Void) {
        self.handler = handler
        GlobalHotkey.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            GlobalHotkey.shared?.handler(); return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x56424259 /* 'VBBY' */), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
```

- [ ] **Step 2: Wire it** in `VibeBuddyMenuBarApp` — register on launch and open the window. In `AppDelegate.applicationDidFinishLaunching`, or as a `@State` in the App, create the hotkey. Simplest: store it on the `AppDelegate` and post a notification the App observes, OR capture `openWindow` via an `NSApp` activation. Concrete approach — in `AppDelegate`:
```swift
    var hotkey: GlobalHotkey?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hotkey = GlobalHotkey {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // Open the dashboard window by id via the standard responder chain:
            if let url = URL(string: "vibebuddy://dashboard") { /* if using URL routing */ }
            NotificationCenter.default.post(name: .init("vibebuddy.openDashboard"), object: nil)
        }
    }
```
And in the App scene, observe that notification to call `openWindow(id:"dashboard")`. (If observing from a `Scene` is awkward, an acceptable alternative: give `MenuBarModel` an `@Published var openDashboardRequest = UUID()` the hotkey bumps, and a hidden `.onChange` in a always-present view — e.g. the `MenuBarExtra` label — calls `openWindow`. Use whichever compiles cleanly; document the choice.)

- [ ] **Step 3: Build + run check** — app build → `** BUILD SUCCEEDED **`. Manual: press ⌃⌥⇧⌘', confirm the window opens/focuses.

- [ ] **Step 4: Commit**
```bash
git add VibeBuddyMacApp/Sources/GlobalHotkey.swift VibeBuddyMacApp/Sources/VibeBuddyMenuBarApp.swift
git commit -m "feat(mac): global hotkey (⌃⌥⇧⌘') opens the dashboard"
```

---

## Task 6: In-window status switching shortcuts (⌘1/2/3, ⌘F)

**Files:** Modify `VibeBuddyMacApp/Sources/DashboardView.swift`

- [ ] **Step 1: Implement** — add hidden buttons with keyboard shortcuts to switch the status filter (A/D approve-deny already on the detail buttons; search focus ⌘F is provided by `.searchable` + `⌘F`-style — but make ⌘1/2/3 explicit). Add to `DashboardView.body`'s top-level container a `.background` of hidden shortcut buttons:
```swift
        .background {
            Group {
                Button("") { statusFilter = .needsResponse }.keyboardShortcut("1", modifiers: .command)
                Button("") { statusFilter = .working }.keyboardShortcut("2", modifiers: .command)
                Button("") { statusFilter = .done }.keyboardShortcut("3", modifiers: .command)
            }.opacity(0)
        }
```

- [ ] **Step 2: Build to verify** — app build → `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**
```bash
git add VibeBuddyMacApp/Sources/DashboardView.swift
git commit -m "feat(mac): ⌘1/2/3 status switching in the dashboard"
```

---

## Task 7: Build, deploy, live verify

- [ ] **Step 1** — Full app build (Release), then redeploy the menu-bar app:
```bash
cd VibeBuddyMacApp && xcodegen generate && xcodebuild -project VibeBuddyMacApp.xcodeproj -scheme VibeBuddyMacApp -configuration Release -derivedDataPath build build
osascript -e 'tell application "VibeBuddyMacApp" to quit'; sleep 2; pkill -x VibeBuddyMacApp
rm -rf /Applications/VibeBuddyMacApp.app && ditto VibeBuddyMacApp/build/Build/Products/Release/VibeBuddyMacApp.app /Applications/VibeBuddyMacApp.app
open /Applications/VibeBuddyMacApp.app
```
- [ ] **Step 2** — Press ⌃⌥⇧⌘' → the dashboard window opens with live sessions; sidebar filters work; ↑/↓ selects; search filters.
- [ ] **Step 3** — With the `--approval` hook enabled, trigger a non-allow command (or POST a fake `/approval` like in the remote-approval verification). Confirm the session shows in the window with the command + 批准/拒绝; click 批准 (or press **A**) → the held command is released. This exercises the Mac-side approval reusing the built backend.

---

## Self-review notes
- **Spec coverage:** window + 3-pane (T3) · status/agent/search filter (T1 logic + T3 UI) · Mac-side approve/deny reusing the registry (T2 + T3 buttons) · global hotkey (T5) · keyboard shortcuts ↑↓ (List selection), A/D (detail buttons), ⌘1/2/3 (T6), search (T3 `.searchable`) · jump-back stubbed (T3) · present-only agent filter (T1 `presentAgents` + T3). All mapped.
- **Type consistency:** `SessionFilter.apply(_:status:agent:query:)` / `presentAgents(_:)`, `MenuBarModel.decide(_:approve:)`, `ApprovalRegistry.resolve(id:with:)`, `AgentSession.pendingApproval` used consistently.
- **Known SwiftUI/AppKit risks (flagged for implementers):** (1) opening a real `Window` from a `MenuBarExtra` accessory app needs `setActivationPolicy(.regular)` + `NSApp.activate` — handled in T4/T5; (2) wiring the global-hotkey callback to `openWindow(id:)` across the AppDelegate/Scene boundary is the fiddliest bit (T5 gives two acceptable approaches — use whichever compiles); (3) always `xcodegen generate` after adding a file. None of these are unit-testable — verify by build + run.
