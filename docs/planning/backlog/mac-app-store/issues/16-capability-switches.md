# 16 — 商店界面只提供可执行能力，用量与 Jump 如实反馈

Status: ready-for-agent
Progress: not-started
Priority: next-cycle-important
Owner: unassigned
Blocked by: 13 关卡：真实 Claude 任务从手机批准、拒绝与回答
Spec: Spec v2（本工作线综合稿）

## What to build

用户连接商店版时看不到 Dispatch、Attach 等不可用控制入口，跳转实际激活宿主应用，Claude 用量反映 Live usage feed，未知额度明确显示未知。商店运行时隔离覆盖所有入口，保留已通过 13 的审批与问题回答。

## Acceptance criteria

- [ ] iPhone 连接商店版时快照 dispatchAgents 为空且无 New task；连接支持 Dispatch 的直接版时仍可用，Mac 自身入口同步受限。
- [ ] 禁用能力在 Mac、iPhone、语音及服务端均不能执行，包括 Attach、终端注入、Steer/continue、精确定位和外部采集；不能只隐藏按钮。
- [ ] Jump 实际将对应终端或宿主拉到前台，复用 activatedApp 文案，不新增线协议或承诺精确标签页。
- [ ] Claude 额度随 Live usage feed 更新，缺失/过期显示真实未知或 stale；Codex 与无法采集的额度不显示假数据，不启动外部采集器。
- [ ] 有效 Hook 审批和 question relay 仍可往返，不能因禁用泛化控制而破坏 13 的能力。
- [ ] 保留/降级/隐藏清单逐项附依据；保留的通知、Glance、宠物、菜单栏、可选语音、登录启动和 Presence 进行受影响的实际验证，用途拒绝或不可用有明确反馈。
- [ ] 直接版行为不变；仅运行与本票影响有关的必要测试和真实流程。

## Readiness and verification

09 已完成启动所需最小禁用，本票完成一致的用户体验与入口覆盖；不重复建立第二套能力协议。

验证采用隔离实际应用和真实代理的用户结果；复用已有 Server、存储、安装器与 Keychain 注入边界。实现时运行两个共享包的必要测试；构建、模拟/fixture 与真实手机验收分别留证，不为拆票增加无关抽象。

## 执行边界

本轮为 to-tickets 整理，未授权开始第二阶段。实施确认后只领取所有 Blocked by 已完成的票，领取写 Owner，全部验收具备证据后才写 Progress: completed。全部工作使用隔离商店 target 和配置；直接版构建、签名、Sparkle、行为不变，不替换日常应用，不占 9876/9877，不改真实代理配置或凭据，不新增临时例外、第二安装包或 bridge，不提交/推送/同步/发布。日志和票不含 token、key 或用户目录内容。具体源码定位、命令与执行证据留在实施方案和验收记录中。

## Comments

- 2026-09-08：由 SPEC-store-v1 拆出，取代 02–08 候选票。

- 2026-09-08 Codex 第一阶段静态评估（未领取、未实施）：JumpOutcome.swift:14 已有 activatedApp，删除新增枚举及旧客户端兼容方案；AccountUsageCoordinator 位于 app 层，MenuBarModel 自算 dispatchAgents，已补两处入口。共享 Core 的“不编入”统一改运行时禁用，覆盖服务端及语音而非仅隐藏 UI。 详见修订后的 IMPLEMENTATION-PLAN.html 票 16；实现与验收仍未执行。

- 2026-09-08 to-tickets：依据 Spec v2 重写为可验证的用户行为切片，保留编号、历史 Comments 和未领取状态；当前正文替代此前分歧建议，具体实现方法仍需实际验证。Status 调整为 ready-for-agent；不代表已确认实施。
