# 02: A-12 公开版关 App 提醒——CloudKit 私有库推送进正式 App

**Status:** in-progress — 代码与开发环境（Development）验收完成（2026-09-26）；剩 Production schema 部署与 Production 复测，放在下一次发布前

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

- [x] Kit：`CloudKitCue` 共用描述（字段名、订阅规格、`ck` → userInfo 映射、TTL），少量纯逻辑测试。
- [x] iPhone：iCloud 权限；通知服务扩展 target；订阅登记（首次启动 + 设置变化）；设备登记带 CloudKit 用户 ID；后台 push 处理认得 `ck` payload。
- [x] Mac：CloudKit 发送器（先查本进程有没有 iCloud 权限，没有就不碰 CloudKit）；接进 `pushToPhones` 的分流与 hold；TTL 清理；设置行。
- [x] 签名：`redeploy-mac.sh` / `release-mac.sh` 只在找到匹配的描述文件时才加 iCloud 权限并嵌入描述文件，找不到就照旧签，不能签出启动不了的包。
- [x] 验收（Development）：隔离 Mac 开发版 + Hermes 开发版，锁屏、App 已结束，20 条；手机按钮；手表按钮。详见 Comments。
- [x] 隐私政策加上「提醒经你自己的 iCloud 私有库」一段。
- [ ] 发布前：CloudKit Console 部署 Production schema；公证版 Mac + Production iPhone 复测一次（`docs/sparkle-setup.md` Per release 第 4 步）。
- [ ] 补测：手动上滑划掉 App 后的送达、按钮冷启动（App 不在运行时点按钮）。

## Comments

### 2026-09-26 Development 环境验收

证据在 `~/Projects/_shared-work/iOS-vibebuddy/a12-e2e/`：`root/notification-delivery.json`、`root/device-registry.json`、`receipts-run20.json`、`proxy.log`、`root/lifecycle-journal.json`。

**环境**
- Mac：本分支的 Release 构建，复制成 E2E 实例 `com.vibebuddy.e2e.ck`，端口 19877，Apple Development 签名，并嵌入 `tools/fetch-mac-cloudkit-profiles.sh` 生成的开发描述文件（CloudKit Development 环境）。正式安装的 App 没动。
- iPhone：本分支 Debug 构建装在 Hermes 上，用 devicectl 环境变量临时指向 E2E 实例（不改已保存的配对）。
- 设备登记里带上了 `cloudKitUser`，Mac 与手机两端都是同一个 `_a818…`。

**结果**
1. **延迟**：20 条审批中，Mac 为 19 条决定了提醒，19 条全部存进 iCloud，手机通知扩展 19/19 收到并取回加密详情，没有一条被静默。
   - 手机锁屏，App 已结束：用 `devicectl terminate --kill`，全程进程表里 0 个 App 进程。
   - 从 Mac 开始保存到扩展收到：p50 1.31 s，p95 1.75 s，max 1.75 s（Mac 与手机时钟，偏差 < 0.5 s，见 01）。
   - 另外 1 条（`a12-ck-12`）Mac 的提醒引擎根本没决定发，本地通道也没有记录，与 CloudKit 通道无关，当作观察项。
2. **ADR-0012 去重**：App 在前台连着时，手机自己发本地通知，Mac 记 `cloudkit skipped phonePosted`，不再存记录。App 在后台、推送先到时，手机记 `phone skipped pushCovered`，没有第二条横幅。两个方向都按原设计工作。
3. **手机按钮**：锁屏收到的 CloudKit 提醒上长按点 Approve，手机发出 `POST /decision`，`approvalId` 为 `B7333FB7…`，正是扩展从 `ck` 字段映射出来的；Mac 放行，hook 返回 `allow`。这次 App 在后台运行，不是冷启动。
4. **手表按钮**：手机锁屏、App 已断开，CloudKit 提醒 10:03:01 发出，10:03:14 审批被放行（`approvalResolved`）。这期间手机在后台被唤醒，依次发了 `/health`、`/snapshot`、`/device`，然后是决定。你当时在手表上点的「批准」。
5. **Mac 设置**：没配 `.p8` 时，「投递健康」下多一行「iCloud 提醒」。它的状态逻辑与发送共用 `cloudKitStatus`；这次没截到设置窗口的图。

**过程中修掉的两个问题**
- 设备登记合并时丢了 `cloudKitUser`，导致 Mac 找不到可发的手机。已修，并加了回归测试 `DeviceRegistryTests.cloudKitFieldsSurviveRegistrationAndRestart`。
- 菜单栏 App 每 2 s 都查一次 iCloud 账号，改为可用时缓存 5 分钟、不可用时 30 秒。

**尚未验证**
- Production 环境：schema 未部署。
- 手动上滑后的送达。
- 按钮冷启动。
- 专注模式下 Time Sensitive 能否穿透。
- 同一 Apple 账号下多台手机。
- 不同 Apple 账号时的提示：代码已写，没有第二个账号可测。
