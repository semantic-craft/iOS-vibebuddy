# Codex rollout → SQLite 迁移观察

Type: observation
当前处置：只观察，不是待实施工单，不设 owner 或执行排期。2026-10-12 用户要求从施工票移出。

## 触发前提

重新评估需有实际证据：rollout 停止写入，并影响现行 Codex 观测/控制路径。`sqlite removed true` 或旧 `codex-dev.db` 存在单独不成立。届时核实真实源/版本及影响，再确定必要改动；SQLite 降级显示和 `codex queue --thread` 仅是旧候选，不保证当前或未来 CLI 契约，也不是自动开工指令。

## 已有观察

- 2026-09-21：0.153.4 仍写 rollout；`thread/list` 已报 `historyMode: paginated`。
- 2026-10-12：Codex CLI 0.162.1，sqlite removed=true；只核对本机 rollout 元数据，当日 48 份、最新仍在写入。旧 codex-dev.db 存在不证明迁移完成，触发前提未成立。见 [补验记录](../../../qa/acceptance-closeout-2026-10-12.md) 和 [计划收尾](../../../qa/deferred-plan-closeout-2026-10-12.md)。

这是时点记录，不代表持续监控；本次没有新增轮询、自动化、数据读取或备用观察实现。
