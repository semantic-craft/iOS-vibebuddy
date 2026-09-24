# 06: 观测健康诊断补 Cursor 行

**What to build:** `ObservationHealthDetector.detect` 增加 Cursor（hook / transcript / acp / cloud 四来源的最近信号与健康），设置页诊断列表出现 Cursor。

**Blocked by:** None

**Status:** done（PR #278）

- [x] 检测逻辑 + `ObservationHealthDetectorTests`（用真实安装器的输出测已装 / 未装；另有 `CLAUDE_CONFIG_DIR` / `CODEX_HOME` 重定向测试）。
- [x] 验收：隔离 `vibebuddyd`（:18796、一次性 HOME）的快照里有 Cursor 行，共四个来源；没装 hooks 时是 `notInstalled`，装上后是 awaitingActivity，收到一个 `sessionStart` 后变 healthy。设置页界面是同一份数据，等协调会话统一重新部署后再看一眼。

## Comments

- 2026-09-24 装机后（`/Applications` 从 main 9137f92f 重建）：已装 App 的快照 `observationDiagnostics` 里有 Cursor 行，共四个来源。本机装了 Cursor，但没有 `~/.cursor/hooks.json`，所以 hook 来源显示 `eventsMissing` / `configurationIncomplete`，不是 `notInstalled`。这与 Claude、Codex、Grok 的规则一致：CLI 在、hook 缺，就算配置不全；`notInstalled` 只在连 `~/.cursor` 都没有时出现。其余三个来源：transcript `temporarilySilent`，acp `acpIdle`，cloud `notInstalled`。设置页截图没拍，因为那个会话没拿到 computer use 授权。
