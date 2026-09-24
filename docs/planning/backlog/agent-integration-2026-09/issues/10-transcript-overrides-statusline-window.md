# 10: 转录读取不要覆盖状态行给的上下文窗口和型号

**What to build:** `SessionReducer.enrich` 读到转录里的 `contextTokens` 时，会用型号表（Claude 一律 200k）重设 `contextWindow`，并用转录里的模型 id 覆盖 `model`。状态行已经给了真实窗口（例如 1M）和显示名时，应当以状态行为准：转录只更新 token 数，不改窗口和型号。

**Blocked by:** None

**Status:** done（PR 待合并，号见 README）；真实 Claude 会话的一次复看随下次装机

**依据（2026-09-24 路线图验收，B-U 状态行字段）：** 真实 Claude 2.1.281 会话、Opus 5.5 (1M context)。10:10–10:11 状态行把 `model`「Opus 5.5 (1M context)」、`contextWindow` 1000000 写进会话行（statusline 观测 `healthy`）。到 10:13:01，同一会话的快照已变成 `model: "claude-opus-5-5"`、`contextWindow: 200000`、`contextTokens: 40039`：转录读取把它们改掉了。结果是 1M 上下文的会话，在两次状态行之间显示占用约 20%，实际约 4%。代码位置：`VibeBuddyMac/Sources/VibeBuddyMacCore/SessionReducer.swift` 的 `enrich`（`s.contextWindow = info.contextWindow ?? Self.contextWindow(for: …)`、`if let model = info.model { s.model = model }`），而 `applyStatusLine` 的注释写的是状态行的数字优先于转录估算。证据：`~/Projects/_shared-work/iOS-vibebuddy/roadmap-agent-acceptance-2026-09-24/bu/presence-away-snapshot.json`。

- [x] 会话已有状态行来源的窗口时，`enrich` 不改 `contextWindow`；没有状态行时保持现有行为（Grok 的 `signals.json` 窗口仍然优先于型号表）。
- [x] 型号同理：状态行给过显示名时，转录的模型 id 不覆盖它（或者只在状态行没来过时写）。
- [x] 回归测试：先喂一个带 1M 窗口的状态行样本，再喂一次带 `contextTokens` 的转录，窗口仍是 1M、型号仍是状态行的显示名。
- [ ] 验收：隔离服务上跑真实 Claude 会话，状态行之后等一次转录读取，快照里的窗口和型号不变。

## Comments

**2026-09-24 实现：** `SessionReducer` 记下状态行报过型号 / 窗口的会话（两个集合，随 `SessionEnd` 和过期清理一起清）；`enrich` 对这些会话只更新 token 数。状态行只给 token、不给窗口时照旧由转录补窗口。模型切换（`PostModelSwitch`）会让状态行的型号和窗口过时，所以同时清掉这两个标记，转录重新可以补，直到下一次状态行。Grok / Codex / Cursor 不走状态行，行为不变。

- 回归测试 `EnrichmentTests`「a transcript read between status-line samples keeps the 1M window and display name」：去掉修复时失败（窗口变 200k、型号变 `claude-opus-5-5`），加上后通过；另一条测试锁住模型切换和会话结束后标记会清掉。
- 全量 `swift test`：1253 项 Swift Testing + 57 项 XCTest 通过（本机负载 700–900 时有一轮 `CompletionNoticeIntegrationTests` 超时失败，单独跑和重跑全量都通过，与本改动无关）。
- 隔离 vibebuddyd（:18797，一次性 HOME）：`UserPromptSubmit` → `/statusline`（1M、「Opus 5.5 (1M context)」）→ 带 `transcript_path` 的 `PostToolUse`：快照为 `Opus 5.5 (1M context)` / 1000000 / 40039（token 数随转录更新）；再发 `PostModelSwitch` 和一次转录读取后，转录重新补为 `claude-opus-5-5` / 200000。
- 没做：真实 Claude 1M 会话在装机版上的复看（本会话不替换 /Applications，随 PERF-02 会话的下次装机一起看）。hook 事件（`SessionStart` 带 `model`）仍会把显示名换成原始 id，只到下一次状态行为止，不在本票范围。

