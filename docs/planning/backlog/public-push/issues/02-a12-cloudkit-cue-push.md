# 02: A-12 公开版关 App 提醒——CloudKit 私有库推送进正式 App

**Status:** in-progress

**Blocked by:** None（01 门槛已过，#320）

**Node:** A-12（ADR-0013 方向 D）

**Executor:** Claude（Opus 5.5）· 分支 `claude/a12-cloudkit-push` · 2026-09-26

## 目标

陌生用户用 App Store 的 iPhone App + GitHub DMG 的 Mac App，不配 `.p8`，App 关掉、手机锁屏也能收到带「批准 / 拒绝」「回复」按钮的提醒。自用 `.p8`（B）照旧，是覆盖路径。

## 已定的做法（依据：01 的实测与 7 条条件）

1. **谁写记录**：只有菜单栏 App。`vibebuddyd` 不是 App 包，拿不到 iCloud 权限，继续只走 `.p8`。
2. **何时走 CloudKit**：这台 Mac 没配 `.p8`、iCloud 可用、至少一台已登记的手机报告了同一个 iCloud 用户 ID。配了 `.p8` 就只走 `.p8`（按 Mac 选一路，01 条件 5）。ADR-0012 的「先等手机回执」照旧：等回执期间不存记录。
3. **容器与环境**：正式容器 `iCloud.com.vibebuddy.app`。Developer ID 包被强制用 Production；App Store 的 iPhone 也是 Production。开发时 iPhone Debug 默认 Development。环境不一致就收不到：Mac 设置里的 CloudKit 行会写明当前环境。
4. **记录**：zone `Cues`，类型 `Cue`。
   - 明文字段只有 `kind`（`approval` / `question` / `done`）、`nid`（`NotificationIdentity.id`，做 collapse id）、`sid`（sessionId）、`rid`（approvalId 或 questionId）、`sentAt`。
   - 标题、正文、项目名都放 `encryptedValues`。
   - 订阅三条（每种 kind 一条，category 固定在订阅上），`desiredKeys = [nid, sid, rid]`，`collapseIDKey = nid`，通用提示文案，`shouldSendMutableContent`。
   - Mac 按 TTL（10 分钟）删除，不按回执删除，因为同账号的每台设备都会收到（01 条件 4）。
5. **通知服务扩展（新 target）**：
   - 把 `ck` payload 映射成正式版读取的 `sessionId` / `approvalId` / `questionId`（01 条件 7）。
   - 取记录，填入标题、正文和副标题。
   - 按本机声音设置与安静模式调声音和级别；该响的设为 Time Sensitive。
   - 取不到记录时保留通用文案。
   - 扩展不能丢弃通知（过滤权限 Apple 不发），所以某台手机关掉的类别只能降成静默，不能不显示。这是 v1 的已知限制。
6. **账号比对**：
   - 手机在设备登记里带上自己的 CloudKit 用户 ID；Mac 用自己的比对。
   - 不一致或 iCloud 不可用时，Mac 设置里的 CloudKit 行写明原因。

## 分步

- [ ] Kit：`CloudKitCue` 共用描述（字段名、订阅规格、`ck` → userInfo 映射、TTL），少量纯逻辑测试。
- [ ] iPhone：iCloud 权限；通知服务扩展 target；订阅登记（首次启动 + 设置变化）；设备登记带 CloudKit 用户 ID；后台 push 处理认得 `ck` payload。
- [ ] Mac：CloudKit 发送器（先查本进程有没有 iCloud 权限，没有就不碰 CloudKit）；接进 `pushToPhones` 的分流与 hold；TTL 清理；设置行。
- [ ] 签名：`redeploy-mac.sh` / `release-mac.sh` 只在找到匹配的描述文件时才加 iCloud 权限并嵌入描述文件，找不到就照旧签，不能签出启动不了的包。
- [ ] 验收：
  - 隔离 Mac 开发版 + Hermes 开发版（Development）：锁屏、手动上滑、20 条、按钮冷启动、手表。
  - 再部署 Production schema，用 Production 复测。
  - 隐私政策加一句"提醒经你自己的 iCloud 私有库"。

## Comments
