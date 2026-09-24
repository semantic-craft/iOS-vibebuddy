# 10: 转录读取不要覆盖状态行给的上下文窗口和型号

**What to build:** `SessionReducer.enrich` 读到转录里的 `contextTokens` 时，会用型号表（Claude 一律 200k）重设 `contextWindow`，并用转录里的模型 id 覆盖 `model`。状态行已经给了真实窗口（例如 1M）和显示名时，应当以状态行为准：转录只更新 token 数，不改窗口和型号。

**Blocked by:** None

**Status:** ready-for-agent

**依据（2026-09-24 路线图验收，B-U 状态行字段）：** 真实 Claude 2.1.281 会话、Opus 5.5 (1M context)。10:10–10:11 状态行把 `model`「Opus 5.5 (1M context)」、`contextWindow` 1000000 写进会话行（statusline 观测 `healthy`）。到 10:13:01，同一会话的快照已变成 `model: "claude-opus-5-5"`、`contextWindow: 200000`、`contextTokens: 40039`：转录读取把它们改掉了。结果是 1M 上下文的会话，在两次状态行之间显示占用约 20%，实际约 4%。代码位置：`VibeBuddyMac/Sources/VibeBuddyMacCore/SessionReducer.swift` 的 `enrich`（`s.contextWindow = info.contextWindow ?? Self.contextWindow(for: …)`、`if let model = info.model { s.model = model }`），而 `applyStatusLine` 的注释写的是状态行的数字优先于转录估算。证据：`~/Projects/_shared-work/iOS-vibebuddy/roadmap-agent-acceptance-2026-09-24/bu/presence-away-snapshot.json`。

- [ ] 会话已有状态行来源的窗口时，`enrich` 不改 `contextWindow`；没有状态行时保持现有行为（Grok 的 `signals.json` 窗口仍然优先于型号表）。
- [ ] 型号同理：状态行给过显示名时，转录的模型 id 不覆盖它（或者只在状态行没来过时写）。
- [ ] 回归测试：先喂一个带 1M 窗口的状态行样本，再喂一次带 `contextTokens` 的转录，窗口仍是 1M、型号仍是状态行的显示名。
- [ ] 验收：隔离服务上跑真实 Claude 会话，状态行之后等一次转录读取，快照里的窗口和型号不变。
