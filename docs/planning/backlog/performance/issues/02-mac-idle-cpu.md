# 02: Mac App 空闲 CPU 降到 2% 以下

**Status:** ready-for-agent

**Blocked by:** None

## 为什么

PERF-01 收尾后（#287、#290、#293，装机 main b07b2dab），负载和内存都达标：5–6 个 working 会话时 CPU 均值 6.2%，2 h 内存曲线在 254 MB 持平。只有空闲一项没达标：本机 0 个 working 会话、10 min、启动后等待 ≥ 90 s，CPU 均值 **2.56%**、p95 4.2%，目标 < 2%。#293 修复前是 3.09%。证据在 `~/Projects/_shared-work/iOS-vibebuddy/acceptance-2026-09-24/13-perf-final/`（`0-idle.csv`、60 s `sample-idle.txt`）。

空闲时间分散在几处常驻轮询上，没有单一热点。下面是 60 s `sample` 中 App 自身的帧，约 60 000 个样本合一个核：

- 2 s 一次的主轮询（`MenuBarModel.startPolling`，约 470），其中快照组装 `SessionStore.currentSnapshot` 约 450：133 个会话，加上对 1549 条回顾账本的 `RecapLedger.recap`（约 180）。
- Cursor 转录轮询，每 2 s 一次，覆盖约 124 个文件（`CursorTranscripts.discover`，约 300）。
- `claude agents --json` 刷新（`ClaudeAgentsSource.runCLI`，约 260）。这部分主要是在等管道；子进程的 CPU 不算在 App 头上。
- Codex rollout 候选扫描（约 110），`CursorComposerStore.refresh`（约 100），观测健康诊断（约 70），工具账本写盘（约 70）。

## 要做的

- 对每一处测量每分钟调用次数和单次耗时（`os_signpost` 或计数日志），先挑最大的两项。
- 候选做法：
  - Cursor 转录改用 FSEvents / kqueue 监听目录变化，或在没有 Cursor 活动时拉长轮询间隔。
  - 空闲时（没有 working / needsResponse 会话，也没有打开的界面）拉长主轮询间隔。
  - 快照未变化时不重算回顾。
  - 注意：不合并 recap ledger 的快照组装（已知约束，见 `SessionStore` 注释），不能以牺牲审批和提醒的时效为代价。

## 验收

- [ ] 装机版，0 个 working 会话，10 min，启动后等待 ≥ 90 s：CPU 均值 < 2%。
- [ ] 5 个活跃会话 < 10%；2 h 内存不单调增长，保持 PERF-01 的结果。
- [ ] 审批卡片出现、完成提醒的延迟不变长（隔离 daemon 端到端 + 手动核对一次）。
- [ ] `swift test` 与 Mac App 构建通过。

## Comments
