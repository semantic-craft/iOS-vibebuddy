# 01: CloudKit 私有库提醒推送原型（公开版 App 关闭后送达，ADR-0013 选项 D）

**Status:** ready-for-agent

**Blocked by:** None

**Node:** A-12 前置（DEC-APNS 已于 2026-09-23 选定方向 D，本票是它的实测门槛）

## 要回答的问题

在不运营中继、不分发 `.p8` 的前提下，陌生用户的 iPhone 在 App 被手动杀掉后，能否及时收到带 VibeBuddy 按钮的提醒。机制：Mac 往用户自己 iCloud 私有库写一条 `Cue` 记录；iPhone 首次启动时建立 `CKQuerySubscription`，其 `CKNotificationInfo` 带 `alertBody`/`title`/`soundName`/`category`/`shouldSendMutableContent`；推送由 Apple 的 CloudKit 服务器签发。依据见 ADR-0013 选项 D。

## 要做的（一次性原型，放 worktree，不进 release）

- iCloud 容器（开发环境）；Mac 端 Developer ID 签名加 iCloud/CloudKit entitlement 与嵌入的描述文件；iOS 端 CloudKit + 远程通知。
- Mac 写记录 → iPhone 横幅；记录推送后删除。
- 在 Hermes 上：iPhone 手动杀 App、锁屏，连续约 20 次，记录 Mac 保存到横幅出现的时间，给出 p50 / p95。
- 验证：`category` 按钮（批准 / 拒绝）可用且回到现有 bearer 通道；Notification Service Extension 能否补充详情与设为 Time Sensitive；同一分钟多条时的合并表现；Mac 与 iPhone 不同 Apple 账号时的失败提示。

## 验收与决定规则

- [ ] 延迟、按钮、NSE、合并四项实测写进本票 Comments，附命令与原始计时。
- [ ] p95 ≤ 30 s 且按钮可用 → A-12 按 D 实现（陌生用户路径），自用 `.p8`（B）保留为低延迟覆盖路径。
- [ ] 否则回到 ADR-0013，把实测交给下一轮决定；不因此转向打包项目密钥（A）或运营中继（C）。
