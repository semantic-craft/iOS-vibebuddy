# 05: 核查同一 Antigravity CLI 会话连续提问的新提醒

Status: needs-triage

Parent: [SPEC](../SPEC.md) · [验收证据](../../../../qa/antigravity-monitor-20261004.md)

## 观察

2026-10-04 实体 Watch 验收：真实 CLI 首轮问题产生 local scheduled / APNs accepted。在原 CLI 回答、看到最终结果后立即发起第二轮问题，产品快照已显示 `AGWATCH-70-R2` / needsResponse / question，但最终发送日志只有首轮 needs_answer。新建会话 R3 能正常推送，用户确认可见与震动。

源代码 `1e050036`（运行 Mac 1.3.44/62），CLI 1.2.16，手机/Watch 1.3.35/70。原会话 `9b527596-6e50-497f-818a-1cc5b3e824a4`。原始证据位于 `~/Projects/_shared-work/iOS-vibebuddy/antigravity-integration-20261004/physical-watch/` 的 waiting、r2、resolved-snapshot 和 final-delivery JSON。

## 待核查

- 重放真实“问题→回答→完成→紧接新问题”并记录 monitor 与 SoundPolicy 收到的状态/turn 边界，确认中间 working/done 是否被轮询或快照合并。
- 区分现行提醒去重策略与新轮次漏提醒；目前尚未定位原因，不推断为 APNs 或手表故障。
- 如确认缺陷，以该时序留下可重放回归检查，并验证新轮次提醒一次、同一等待不重复提醒。
