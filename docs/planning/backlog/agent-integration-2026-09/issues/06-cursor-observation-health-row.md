# 06: 观测健康诊断补 Cursor 行

**What to build:** `ObservationHealthDetector.detect` 增加 Cursor（hook / transcript / acp / cloud 四来源的最近信号与健康），设置页诊断列表出现 Cursor。

**Blocked by:** None

**Status:** ready-for-agent

- [ ] 检测逻辑 + `ObservationHealthDetectorTests`。
- [ ] 验收：设置页看到 Cursor 行；未安装 hooks 时显示 notInstalled 而不是空。
