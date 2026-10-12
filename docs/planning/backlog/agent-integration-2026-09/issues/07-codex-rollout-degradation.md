# 07: Codex rollout → SQLite 迁移的退化预案（观察项）

**What to build:** 检测 `~/.codex/sqlite/codex-dev.db` 存在且 rollout 目录停止增长（`codex features list` 中 `sqlite removed true`），在观测健康里说明"rollout 已被 SQLite 取代，daemon 不可用时 Desktop 观察降级"；`codex queue --thread <id> --message` 作为 app-server 证据过期时的 steer 兜底。

**Blocked by:** None

**Status:** needs-triage（等 Codex 真正停写 rollout 再动手；先记录）

## 2026-10-12 收尾核对

已逐项核对当前 main、合并记录与已有证据，见 [逐项验收表](../../../../qa/housekeeping-2026-10-12.md#agent-integration-2026-09-07)。未复现 rollout 停写触发条件；SQLite 降级与 queue 兜底未核实，观察项保留。 本票仍开放；表中未核实条件不是验收通过。

## Comments

- 2026-09-21：0.153.4 仍写 rollout；`thread/list` 已报 `historyMode: paginated`。

- 2026-10-12 补验：Codex CLI 0.162.1，sqlite removed=true；仅核对本机 rollout 文件元数据，当日 48 份、最新仍在写入。旧 codex-dev.db 存在不证明迁移完成。触发前提未成立，保留观察项，见 [补验记录](../../../../qa/acceptance-closeout-2026-10-12.md)。
