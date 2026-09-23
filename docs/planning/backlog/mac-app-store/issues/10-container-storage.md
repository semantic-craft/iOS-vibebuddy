# 10 — 商店版重启后保留 Pairing 与应用数据

Status: ready-for-agent
Progress: not-started
Priority: next-cycle-important
Owner: unassigned
Blocked by: 09 商店版启动后可与 iPhone Pairing
Spec: Spec v2（本工作线综合稿）

## What to build

用户重启商店版后仍能用原 Pairing 连接，并保留应用自有账本和设置；两版同时存在时互不覆盖。复用既有存储根注入，保留直接版的原路径与大小写，不为了统一路径迁移其缓存。

## Acceptance criteria

- [ ] 商店 bearer token 权限为 0600，重启前后在内存比较相等，手机使用原 Pairing 重新连接成功。
- [ ] 设备注册、Missed、通知投递、LifecycleJournal、用量缓存、注意力覆盖和 always-allow 数据按各功能实际写入容器；重启读取符合其原有保留规则。
- [ ] 惰性数据通过触发对应行为验证；尚未触发的文件如实记录，不能仅创建空文件充当持久化证据。
- [ ] 直接版存储位置与读写行为不变；隔离两实例各自产生测试数据，互不覆盖或读取对方数据。
- [ ] 外部 Claude 后台 jobs 不归类为自有数据；商店不启用后台任务索引读取或 Attach。
- [ ] 只记录根归属、权限和相等结论，不输出 token 或用户目录树。

## Readiness and verification

范围仅为应用自有存储；外部授权由 11 交付，不做广泛存储重构。

验证采用隔离实际应用和真实代理的用户结果；复用已有 Server、存储、安装器与 Keychain 注入边界。实现时运行两个共享包的必要测试；构建、模拟/fixture 与真实手机验收分别留证，不为拆票增加无关抽象。

## 执行边界

本轮为 to-tickets 整理，未授权开始第二阶段。实施确认后只领取所有 Blocked by 已完成的票，领取写 Owner，全部验收具备证据后才写 Progress: completed。全部工作使用隔离商店 target 和配置；直接版构建、签名、Sparkle、行为不变，不替换日常应用，不占 9876/9877，不改真实代理配置或凭据，不新增临时例外、第二安装包或 bridge，不提交/推送/同步/发布。日志和票不含 token、key 或用户目录内容。具体源码定位、命令与执行证据留在实施方案和验收记录中。

## Comments

- 2026-09-08：由 SPEC-store-v1 拆出，取代 02–08 候选票。

- 2026-09-08 Codex 第一阶段静态评估（未领取、未实施）：AccountUsage.swift:341 的大写 V 路径必须保留，撤销候选中的迁移/缓存失效方案。ClaudeBackgroundSessions.swift:29–40 读 .claude/jobs 外部文件，不属于本票容器数据。 详见修订后的 IMPLEMENTATION-PLAN.html 票 10；实现与验收仍未执行。

- 2026-09-08 to-tickets：依据 Spec v2 重写为可验证的用户行为切片，保留编号、历史 Comments 和未领取状态；当前正文替代此前分歧建议，具体实现方法仍需实际验证。Status 调整为 ready-for-agent；不代表已确认实施。
