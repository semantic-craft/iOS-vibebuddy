# 18 — 准备与已验收能力一致的 Archive 和审核材料

Status: needs-triage
Progress: not-started
Priority: next-cycle-important
Owner: unassigned
Blocked by: 14 Codex CLI 可从手机放行，其它 CLI 可观察；15 Codex Desktop 等待时收到明确只读提醒；16 商店界面只提供可执行能力，用量与 Jump 如实反馈；17 两版接管 Hook 不争抢，Keychain 状态如实呈现
Spec: Spec v2（本工作线综合稿）

## What to build

准备本地可核验的商店 Archive、隐私说明、截图与 reviewer 演示步骤，让审核材料准确反映已完成能力；不上传、不提交、不修改 App Store Connect 记录。

## Acceptance criteria

- [ ] 实际 Archive 的签名、app-sandbox 与资源检查通过，无 temporary-exception、Sparkle 或自更新入口；本地 Apple Development 验证与分发归档分别记录。
- [ ] 审核备注准确说明用户目录授权、必要配置修改、代码留在 bundle 内和无自更新；OpenCode 实现与描述一致，不声称已获合规确认。
- [ ] 隐私和用途说明覆盖实际麦克风、局域网、可选语音提供商及通知数据流；截图不泄露 token、key、用户目录内容或 Pairing QR。
- [ ] 在可用干净账户按 reviewer 步骤实际完成演示，记录结果；Demo Mode 不冒充真实 agent 审批证据。
- [ ] 账号平台及签名资料前置条件只读核实；缺 profile/账户等条件如实列明，不自动创建账户、联网申请签名资料或修改商店记录。
- [ ] 上传、提交、审核结果留空；仅本地材料完成不得标发布或审核通过。

## Readiness and verification

需先完成 14–17，明确真实验收范围并确认可用的分发签名与干净账户环境后再 triage。

验证采用隔离实际应用和真实代理的用户结果；复用已有 Server、存储、安装器与 Keychain 注入边界。实现时运行两个共享包的必要测试；构建、模拟/fixture 与真实手机验收分别留证，不为拆票增加无关抽象。

## 执行边界

本轮为 to-tickets 整理，未授权开始第二阶段。实施确认后只领取所有 Blocked by 已完成的票，领取写 Owner，全部验收具备证据后才写 Progress: completed。全部工作使用隔离商店 target 和配置；直接版构建、签名、Sparkle、行为不变，不替换日常应用，不占 9876/9877，不改真实代理配置或凭据，不新增临时例外、第二安装包或 bridge，不提交/推送/同步/发布。日志和票不含 token、key 或用户目录内容。具体源码定位、命令与执行证据留在实施方案和验收记录中。

## Comments

- 2026-09-08：由 SPEC-store-v1 拆出，取代 02–08 候选票。

- 2026-09-08 Codex 第一阶段静态评估（未领取、未实施）：删除候选中自动签名/创建平台/强制导出 pkg 的预设动作；Archive 与 Apple Development 本地沙盒验证分开留证。审核备注改为目录授权，OpenCode 不得一边复制外部代码一边声称只引用 bundle。 详见修订后的 IMPLEMENTATION-PLAN.html 票 18；实现与验收仍未执行。

- 2026-09-08 to-tickets：依据 Spec v2 重写为可验证的用户行为切片，保留编号、历史 Comments 和未领取状态；当前正文替代此前分歧建议，具体实现方法仍需实际验证。Status 调整为 needs-triage；不代表已确认实施。
