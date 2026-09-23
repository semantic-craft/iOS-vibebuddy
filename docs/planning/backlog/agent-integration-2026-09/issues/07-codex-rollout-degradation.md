# 07: Codex rollout → SQLite 迁移的退化预案（观察项）

**What to build:** 检测 `~/.codex/sqlite/codex-dev.db` 存在且 rollout 目录停止增长（`codex features list` 中 `sqlite removed true`），在观测健康里说明"rollout 已被 SQLite 取代，daemon 不可用时 Desktop 观察降级"；`codex queue --thread <id> --message` 作为 app-server 证据过期时的 steer 兜底。

**Blocked by:** None

**Status:** needs-triage（等 Codex 真正停写 rollout 再动手；先记录）

## Comments

- 2026-09-21：0.153.4 仍写 rollout；`thread/list` 已报 `historyMode: paginated`。
