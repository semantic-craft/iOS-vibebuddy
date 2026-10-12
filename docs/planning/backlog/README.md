# 施工清单（2026-10-12 更新）

这里只列**尚未全部验收**的施工项。已完成的改动看 `git log` 和已合并的 PR；各版本做了什么：Mac 看 [GitHub Releases](https://github.com/semantic-craft/iOS-vibebuddy/releases)，iOS 看 App Store 的 What's New。票据做完就删文件和行（见 `docs/agents/issue-tracker.md`）。

2026-10-12 第一轮已逐项核对 21 份开放票，见 [收尾验收表](../../qa/housekeeping-2026-10-12.md)。实现已合并的票不再重复开发；剩余产品验收保留，未核实的条件明确列为缺口。下方无独立工单的开发建议、真机清单和观察项，本次未重新复现或补充完整验收，均为**未核实**，不得据此宣告全项目验收完成。

后续 [补验与结案](../../qa/acceptance-closeout-2026-10-12.md) 已补自动检查并按用户要求关闭 9 票；该轮结束时剩 12 份开放票。真机/耳听及剩余完整产品验收的取消不等于通过；历史规格与证据保留。

当前 [暂不实施计划收尾](../../qa/deferred-plan-closeout-2026-10-12.md) 关闭商店 10 票与 Web 1 票，SQLite 移为观察记录；正式开放施工票为 **0**。关闭原因是用户决定暂不做，不是实现/验收通过。

优先级（2026-09-23 起）：先完善本机 GitHub 公开版的性能和已知问题；Mac App Store 与 Web 接入设计施工票现已关闭；保留设计依据。SQLite 仅观察。

## 开发项

| ID | 内容 | 票据 | 状态 | 说明 |
|---|---|---|---|---|
| E-1 | Icon Composer 分层图标 | — | 可开工 | 仓库只有 `AppIcon.appiconset` PNG；Xcode 27 已在用，原先的阻塞已解除 |
| C-3 / C-5 | 首次运行流程；一等 / 社区级 agent 标注 | — | 部分完成 | #224 加了引导清单；README 已标出部分社区适配。缩小范围后再做 |


## 只剩真机或本人能确认的

不单独约时间，碰上时顺带看：

- **语音耳测**（D-U）：Qwen 打一通短电话，中英文各说一句；OpenAI 补一句英文。听得清、能打断即可。
- **手机锁屏横幅批准要不要 Face ID**（A-03）。
- **在 Cursor IDE 的 agent 里输入一句提示词**（H-5）。
- **手表长文字**（M-07）：长问题或长命令表冠滚到底能读完、批准正常；已完成任务的结果点一次「展开」。
- **远程连接只用官方 Tailscale**（NET-01）：手机关 Wi-Fi 走一遍。
- **通话到顶提示与重拨按钮**（D-1）：只有 Qwen / OpenAI 的 60–120 分钟长通话才会出现，碰上时看一眼。
- **真机 VoiceOver**（G-4 / G-4b）：没人实际听过。
- **A-12 Production 端到端**：没配 `.p8` 的公证版 Mac → App Store 版 iPhone 送达一次（Production schema 已部署，复测没有记录）。
- **手表停下真实 Codex 会话**：Codex 走 `monitor.interrupt`，只验过托管 Cursor；重复点、断线、会话已结束各一次，结果符合 accepted / refused / failed。
- **长显示触觉**：手机锁屏、戴着手表时，抬腕展开的横幅是否播自定义节奏（「需要你」是 5 个长拍）。稳定则触觉文案可写「抬腕即分辨」，否则改成「打开 VibeBuddy 时」。
- **Double Tap**：允许、发送、停下确认三处各一次。

## 观察项（暂不动手）

- **AI-07**：Codex rollout → SQLite 迁移仅作观察，触发前提未成立；见 [观察记录](agent-integration-2026-09/rollout-sqlite-observation.md)。
- **活跃时的写盘**：每个 hook 事件都整份写回日志和最近目录（PERF-02 留下的建议），真实使用中出现卡顿再开票。
- **推送已被苹果接受但手表没出现**：2026-09-24 出现过 2 次，原因未查明，再出现再查。
- **WR-08 余留**：手机锁屏时，刷新成功后中继状态仍显示「连不上 Mac」；手表下拉刷新不发请求（`DashboardStore.relayToWatch`）。
- **WR-11 余留**：Esc 打断后卡片 60 s 内仍可作答，答案被丢弃。
- **AI-02 未做**：以 leader 身份挂上终端里的 Grok，让它也能远程批准。
- **AI-10**：真实 1M 上下文会话复核一次上下文窗口显示。
- **RV-03**：真机语音时留意有没有误扣动作。
- **Codex steer 与额度推送**：额度重置后没重跑。
- **Antigravity hooks**：上游有 bug，已记录在 `docs/multi-cli-hook-setup.md`。
- **Claude `Stop` 的后台任务类型**：子代理起的后台 shell 与 monitor 都报 `type:"shell"`，只影响「还有 N 项后台任务」的计数口径。

## 仍然有效的决定

- **推送**：公开版走 CloudKit 私有库提醒（ADR-0013 方向 D，已随 Mac 1.3.35 / iOS 1.3.30 发布）；自用 `.p8` 保留；打包密钥否决。
- **hook 分发**：Swift 安装器为主，插件暂不做（插件同样被 `allowManagedHooksOnly` 拦截，且装不了主 statusLine）。
- **手表**：M-09 延后，M-10 不做（ADR-0021）。
- **MAS-15**：Codex Desktop 只观察进度，不承诺等待提醒。
- **截图**：用 demo 模式（`VIBEBUDDY_DEMO=1`、`tools/watch-qa-shots.sh`），不做截图矩阵。
- **PR 评审**：见 `docs/agents/pr-review.md`。

## Mac App Store：关闭施工，保留研究

商店 09–18 工单已按用户要求关闭，设计及历史切片见 [CHECKLIST](mac-app-store/CHECKLIST.md)；历史「09 只差真机 Pairing」不成立：09 的实现是未提交改动，所在目录、分支和 stash 都已不存在，`main` 上没有商店 target。

还留着的产品与技术结论，重做时直接沿用：

- 沙盒里连接 Codex socket 会报 EPERM（死路）。
- hooks 入站审批可行，但 hook 必须走 bundle 内路径，不能带 env 前缀。这条的依据是已删除的 python 安装脚本；C-1（#266）已改由 Swift `HookInstaller` 按命令识别，并把直接版的 hook 挪到 `~/Library/Application Support/vibebuddy/bin/`，重启时要按新逻辑重新验证沙盒下的 hook 路径与两版共存方式（票 12、14、17）。
- 沙盒里生成子进程运行 CLI 全部失败。
- 商店版不能继承直接版的 Keychain 条目，而且读取可能挂死。

出处：[RESULTS.md](mac-app-store/evidence/RESULTS.md)、[TRIAGE-14-15-17.md](mac-app-store/evidence/triage/TRIAGE-14-15-17.md)、[CLAUDE-REVIEW.md](mac-app-store/CLAUDE-REVIEW.md)。审核时可引用已上架的同类沙盒应用 Earcon、SessionRadar、Opsnook（历史线索已保留在 RESEARCH.md，未本轮复核）。

## 归档位置

- `~/Projects/_shared-work/archive/iOS-vibebuddy-scratch-2026-09-23.tgz`：完整的 `.scratch`，含已完成工单、HTML 计划、探针和证据；`CHECKLIST.md` 链接的两份 HTML 实施手册和探针源码也在这里。
- 各轮验收证据在 `~/Projects/_shared-work/iOS-vibebuddy/` 下按日期分目录。
