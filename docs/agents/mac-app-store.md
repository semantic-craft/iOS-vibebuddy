# macOS App Store 工作接续

## 已明确的方向

用户于 2026-09-06 将 macOS App Store 版列为下一步重要工作，同时要求完整直接分发版继续。商店版优先评估独立沙盒方案，尽可能保留真实代理任务观察、提醒、审批、问答和可选语音；不默认削减成只读看板。保留 ADR-0002 的可选语音/直连模型，以及 ADR-0013 不运营中转服务的边界。

这是工作优先级与接续入口，不是自动实施、安装、发布或替换当前用户任务的授权。

## 何时读取及如何继续

讨论下一步计划、选择新开发任务，或修改 macOS 分发、沙盒、代理接入相关行为时，读取本文件与 `docs/planning/backlog/mac-app-store/CHECKLIST.md`。用户给了其他明确任务时先完成该任务；不要因此自动启动商店版开发。

- 状态入口：`docs/planning/backlog/mac-app-store/CHECKLIST.md`（随仓库保存；2026-09-23 起 09 需从零重做，见其末节）。
- 候选 spec 和研究：同目录 `PRD.md`、`RESEARCH.md`。
- 工作票：同目录 `issues/`（09–18）；当前有效票与依赖按 checklist 的精确链接定位，不从历史票号推断。实测结论在同目录 `evidence/`。
- Claude 独立评审结果：同目录 `CLAUDE-REVIEW.md`。HTML 实施手册、提示词和探针源码只在 `~/Projects/_shared-work/archive/iOS-vibebuddy-scratch-2026-09-23.tgz`。

领取工作前复核当前源码、git 状态、票 owner 和已有证据；收尾回写 checklist 的下一张票及 ticket 证据。本文件不复制动态状态。

票据和证据随仓库保存；入口存在不能代替实际交付完成。
