# 01: CloudKit 私有库提醒推送原型（公开版 App 关闭后送达，ADR-0013 选项 D）

**Status:** done — 门槛通过（2026-09-26，见 Comments）；A-12 可按 D 实现，带下面列出的条件

**Blocked by:** None

**Node:** A-12 前置（DEC-APNS 已于 2026-09-23 选定方向 D，本票是它的实测门槛）

## 要回答的问题

在不运营中继、不分发 `.p8` 的前提下，陌生用户的 iPhone 在 App 被手动杀掉后，能否及时收到带 VibeBuddy 按钮的提醒。机制：Mac 往用户自己 iCloud 私有库写一条 `Cue` 记录；iPhone 首次启动时建立 `CKQuerySubscription`，其 `CKNotificationInfo` 带 `alertBody`/`title`/`soundName`/`category`/`shouldSendMutableContent`；推送由 Apple 的 CloudKit 服务器签发。依据见 ADR-0013 选项 D。

## 要做的（一次性原型，放 worktree，不进 release）

> 2026-09-26：原型代码按合并规则放进 `prototypes/cloudkit-cue/` 合入 main：独立工程、独立 bundle ID 与容器，正式版和发布脚本都不引用，不进 release。

- iCloud 容器（开发环境）；Mac 端 Developer ID 签名加 iCloud/CloudKit entitlement 与嵌入的描述文件；iOS 端 CloudKit + 远程通知。
- Mac 写记录 → iPhone 横幅；记录推送后删除。
- 在 Hermes 上：iPhone 手动杀 App、锁屏，连续约 20 次，记录 Mac 保存到横幅出现的时间，给出 p50 / p95。
- 验证：`category` 按钮（批准 / 拒绝）可用且回到现有 bearer 通道；Notification Service Extension 能否补充详情与设为 Time Sensitive；同一分钟多条时的合并表现；Mac 与 iPhone 不同 Apple 账号时的失败提示。

## 验收与决定规则

- [x] 延迟、按钮、NSE、合并四项实测写进本票 Comments，附命令与原始计时。
- [x] p95 ≤ 30 s 且按钮可用 → A-12 按 D 实现（陌生用户路径），自用 `.p8`（B）保留为低延迟覆盖路径。**实测 p95 3.4 s，批准按钮可用。**
- [ ] ~~否则回到 ADR-0013~~（不适用），把实测交给下一轮决定；不因此转向打包项目密钥（A）或运营中继（C）。

## Comments

### 2026-09-26 原型门槛：通过

**Executor:** Claude（Opus 5.5）· 分支 `claude/cloudkit-cue-prototype` · 原型代码 `prototypes/cloudkit-cue/`（独立 bundle ID `com.vibebuddy.cueproto*`、独立容器 `iCloud.com.vibebuddy.cueproto`，正式版工程和发布脚本都不引用）。原始事件（每条一行 JSON）与 `report.txt` 在 `~/Projects/_shared-work/iOS-vibebuddy/cloudkit-cue-2026-09-26/`。

**结论：通过。** 在 Hermes 上，手机锁屏、App 不在运行，20 条连续提醒全部送达；从 Mac 开始保存记录到通知扩展把内容交给系统（横幅随即出现），p50 2.0 s、p95 3.4 s（门槛 30 s）；锁屏时收到的提醒上点「批准」，经带 bearer 的 HTTP 回到 Mac（HTTP 200，内容带 cueID）。Developer ID 包的端到端没有测成，被 Production schema 挡住，见下文。自用 `.p8` 路径没有任何改动。

#### 怎么测的

- Mac：`CueProtoMac`（Apple Development 签名，自动签名建了 App ID、容器和描述文件；CloudKit Development 环境）往私有库自定义 zone `Cues` 存 `Cue` 记录，字段 `kind` / `project` / `sessionKey` / `sentAt`，详情放 `encryptedValues["detail"]`。
- iPhone：`CKQuerySubscription` × 2（`kind == approval` / `question`，仅创建时触发，`zoneID = Cues`），`CKNotificationInfo`：`title` / `alertBody`（通用文案）、`soundName`、`category`（与正式版同名的 `approval` / `question`）、`collapseIDKey = sessionKey`、`shouldSendMutableContent`、`desiredKeys = [cueID, sentAt, sessionKey]`（上限 3 个）。
- 通知服务扩展（NSE）：记开始时间；读一个 `.complete` 保护的探针文件判断是否锁屏；按推送里的 recordID 取记录，把加密详情换进正文；设 `interruptionLevel = .timeSensitive`；交给系统后写一条 `Receipt` 回私有库。Mac 通过 zone changes 读回（不需要查询索引），收到回执即删除对应 `Cue`。
- 计时三种口径：① Mac 开始保存 → NSE 交出内容（Mac 时钟 vs 手机时钟）；② 两条记录的 **服务器** `creationDate` 之差（`Cue` 创建 → `Receipt` 创建，同一时钟、无偏差，含回执上传，是上界）；③ Mac 保存调用本身。**主测试没有做 Mac↔手机时钟校正**：01:42 登记时时钟握手没连上 Mac（手机日志 "clock offset unavailable"），`report` 按 0 偏差算。偏差的上界来自数据本身：Mac 每条都满足 `saveStart < 服务器 creationDate < savedAt`；手机与服务器相差 ≤ 0.14 s（`Device` 记录的 `registeredAt` 与服务器 `modificationDate` 之差，含上传）。合起来偏差在 0.5 s 以内，对 30 s 门槛没有影响；02:31 补测到的握手偏差是 0.031 s。口径 ② 不受偏差影响。
- 前置状态：01:42 App 首次运行完成登记（两台设备 `userRecordName` 同为 `_8da8…`，订阅 `cue-approval`、`cue-question` 在 Mac 侧可见，通知已授权，Time Sensitive 设置 = 开）。02:02:49 App 进程结束。用的是 `devicectl device process terminate --kill`，不是原票要求的手动上滑；进程表确认 0 个 App 进程，全程三次复查均为 0，45 s 后开始发送。每条回执的 `locked` = 1。

```bash
CueProtoMac run --out run1 --count 20 --interval 30 --tail 60 --token <t>
```

```bash
CueProtoMac run --out burst --count 5 --burst --tail 45 --token <t>
```

```bash
CueProtoMac run --out same --count 3 --interval 5 --same-session --tail 45 --token <t>
```

#### 延迟（Hermes，锁屏，App 不在运行，Wi-Fi，CloudKit Development 环境 → APNs sandbox）

| 组 | 条数 | 送达 | Mac 开始保存 → NSE 交出内容 p50 / p95 / max | 服务器时钟上界 p50 / p95 | NSE 取加密详情 p50 |
|---|---|---|---|---|---|
| run1，30 s 一条 | 20 | 20/20，无重复 | 1.97 / 3.37 / 3.49 s | 1.61 / 2.46 s | 0.64 s |
| 全部锁屏组（run1 + 突发 + 同会话 + 关专注后 3 条） | 31 | 31/31 | 1.91 / 3.43 / 3.49 s | 1.52 / 2.46 s | 0.45 s（p95 1.1 s） |

- `report` 命令按这个口径计算（`report.txt` 已按修正后的代码重新生成）。Mac 的保存调用本身 p50 1.0 s、p95 2.4 s；推送通常在这次调用返回前后 0.1 s 内就到了手机（run1 "保存完成 → NSE 开始" p50 0.13 s）。所以 A-12 要在后台线程保存，不要等保存完成再做别的事。
- 01:38 的第一次尝试作废：手机上的 App 还没完成登记（没有订阅），3 条都没送达，记录在 `aborted-0138/`。原因是登记在 App 首次打开后约 5–20 s 才完成，第一次打开就被划掉了。A-12 在首次启动界面上要等订阅保存成功再报「已就绪」。

#### 四项验证

1. **按钮（通过，冷启动那半只由默认轻点证明）**：送达的每条通知 `categoryIdentifier = approval`（通知中心回读 15 条，全部是）。手机上长按提醒出现 Approve / Deny（你确认）。三次 Approve 打在 `c360102-0`、`c359419-19`、`c359419-17` 上（02:31:45 / 02:31:54 / 02:32:08），这三条都是锁屏且 App 已结束时收到的。但点按时 App 已在 02:30:50 被打开过（你按我的步骤打开的），所以按钮这一下打到的是在运行或挂起的进程，不是冷启动。`didReceive` 拿到 `approve` 和 `desiredKeys` 里的 `cueID`，POST `/action`（bearer）到 Mac，都是 HTTP 200。后两次 Mac 收到的内容带 cueID，手机 → Mac 0.06 s；02:31:45 那次原型的监听只读了第一个 TCP 段，内容丢了，cueID 靠 CloudKit 的 `Action` 记录对上（监听已改为按 `Content-Length` 读满）。**冷启动 + 通知动作**这条路径由 02:22:09 那次轻点（默认动作）证明：App 不在运行，被通知拉起后 POST 到 Mac，内容带 cueID，0.14 s。「冷启动 + 按钮」放进 A-12 验收补测。正式版的按钮都是 foreground action（ADR-0033），与原型相同。
2. **NSE（通过）**：31/31 条 NSE 都运行了，且都在锁屏状态；31/31 条从 `encryptedValues` 取到详情并换进正文（锁屏时 CloudKit 取数与解密可用，这一点 Apple 文档没写，属于实测结论）。回读到的 `interruptionLevel` 全部 = 2（`.timeSensitive`），说明 NSE 设置的级别生效了（`CKNotificationInfo` 本身没有这个字段）。**没测**：专注模式下 Time Sensitive 能不能穿透。主测试时你开着专注模式，横幅在锁屏上，但没有记录穿透表现。
3. **合并（通过，一项未观测）**：5 条不同会话在 2 s 内连发，5/5 都单独送达（服务器上界 p95 1.3 s），CloudKit 没有合并。同一 `sessionKey` 的 3 条（5 s 一条）3/3 都送达了 NSE，没有被丢。通知的 request identifier 就是 collapse id（回读里 `id == sessionKey`），所以同会话的后一条会在通知中心替换前一条。替换本身没有在回读中观测到：回读前那几条已被清掉。
4. **不同 Apple 账号（设计已定，未实测）**：同账号时两端 `CKContainer.userRecordID().recordName` 完全相同（`_8da8…`，Mac 和 iPhone 各自读到）。A-12 的检测方法：配对时手机把自己的 recordName 经现有 bearer 通道交给 Mac，Mac 比对，不同或 `accountStatus ≠ .available` 就在设置里提示「iPhone 与 Mac 的 Apple 账号不同 / 未登录 iCloud，关掉 App 后收不到提醒」。第二个账号的情况没有实测，因为手边没有第二个账号。

#### 手表

原型只有 iPhone App。你报告手表上**只显示了通知、没有按钮**，这在预料之中：foreground action 需要在点按的设备上打开 App，手表上没有原型的 App，系统就不显示这些按钮；另有开发者论坛报告，无手表 App 的镜像通知只剩 Dismiss（[thread 740711](https://developer.apple.com/forums/thread/740711)，无 Apple 回复）。正式版有手表 App，并注册了同名的 category（`WatchNotificationRouting.categories()`），CloudKit 推送与 `.p8` 推送到了手机上都是可见提醒，但 payload 形状不同（见条件 7），手表上的路由要依赖 NSE 改写后的 userInfo 是否随镜像过去。这一点和手表按钮一起在 A-12 验收里确认。

#### Developer ID（未端到端验证：被 Production schema 挡住）

- 证据：`devid/evidence.txt`（签名、entitlements、描述文件、账号状态、那条报错）。延迟测试用的是 Apple Development 签名的 Mac 包，从 Developer ID 包发出的推送一条都没测。
- `xcodebuild archive` + `-exportArchive`（`method = developer-id`，自动签名）为 Mac 版生成了 "Mac Team Direct Provisioning Profile"，内嵌、硬化运行时、Developer ID Application 签名，能直接运行（未公证，本机执行）。
- **Developer ID 导出会把 `com.apple.developer.icloud-container-environment` 强制改成 `Production`**（我们写的是 `Development`；描述文件里只允许 Production）。用这个包：账号状态可用、在 Production 私有库建 zone 成功；存 `Cue` 失败，报 `Cannot create new type Cue in production schema`。结论：公开版必须先把 schema 部署到 Production；自用的开发版 iPhone 与公证过的 Mac 配对时，iPhone 也要设 `Production`（iOS 开发描述文件同时允许 Production 和 Development，可以设）。
- Apple 的 [Developer ID 页](https://developer.apple.com/developer-id/) 写明 Developer ID 可用 CloudKit。

#### 对照文档与同类项目

- `CKSubscription.h`（Xcode 27 SDK）："You don't need to explicitly enable push notifications for your App ID"；推送发给 "all devices with that subscription except for the one that makes the original changes"。Mac 自己不订阅，也不会收到。
- [QA1917](https://developer.apple.com/library/archive/qa/qa1917/_index.html) 只排除 `shouldSendContentAvailable`（静默推送）送达已强退的 App；本测试用的是可见提醒，结果一致。**注意**：本次 App 进程是被 `devicectl` 结束的，不是你在多任务里上滑划掉的。按 QA1917 推断，两者的区别只影响静默推送的后台唤醒，D 方案不依赖它；这是推断，不是实测，A-12 验收用手动上滑补一次。
- Apple 工程师在论坛上说 "15s is pretty good for end to end with CloudKit"（[thread 682861](https://developer.apple.com/forums/thread/682861)）；本次实测远好于这个数，但 Apple 不承诺延迟，A-12 不能把几秒当保证。
- Tact 2024 年停用自建推送服务器改走 CloudKit 订阅推送；静默推送 "arrived late or not at all"，改成可见推送后可靠（[blog](https://blog.justtact.com/direct-cloudkit-notifications/)、[bugs](https://blog.justtact.com/cloudkit-bugs/)）。与本次选择可见提醒 + NSE 一致。没有找到用 CloudKit 做 Mac→iPhone agent 提醒的开源项目。

#### A-12 实现时的条件（门槛通过不等于这些都免了）

1. 容器用正式的 `iCloud.com.vibebuddy.app`（原型容器只用于原型）；schema 部署到 Production；上线后在 Production + 生产 APNs 上跑一次同样的 20 条（本次是 Development + sandbox）。
2. 首次启动等订阅保存成功才报就绪；配对时比对 `userRecordName`，失败时给出提示。
3. 提醒文案保持通用（Apple 能看到），详情和项目名都放 `encryptedValues`，由 NSE 取回（原型把 `project` 放在明文字段里当副标题，A-12 不要这样做）；`desiredKeys` 最多 3 个，字符串超过 100 字会被截断。
4. 每种 category 一条订阅（category 固定在订阅上）。CloudKit 订阅属于整个账号，同一 Apple 账号下装了 App 的每台设备（第二台 iPhone、iPad）都会收到推送，所以不能「第一条回执到了就删记录」：慢一点的设备的 NSE 会取不到记录，正文退回通用文案。只按 TTL 删除（比如 10 分钟），或等所有已登记设备都回执后再删。
5. 前台和局域网通道照旧。`.p8` 自用路径保留为覆盖路径。CloudKit 推送没法按设备关掉，Mac 只能决定这一条存不存：存了，账号下每台设备都会响；不存，每台都收不到。所以「走 `.p8` 还是走 CloudKit」按 Mac（即按账号）选，不按手机选；选 `.p8` 的 Mac 不存记录，没有配 `.p8` 的其他设备也就收不到关 App 提醒。ADR-0012 的「Mac 先等手机回执再发推送」照样适用：等回执期间先不存记录；记录一旦存下，推送就撤不回了。
6. 手表按钮与路由、专注模式下的 Time Sensitive 穿透、不同 Apple 账号的提示、冷启动 + 按钮、手动上滑后的送达，在 A-12 验收里补测。
7. **payload 形状不同**：CloudKit 推送的 userInfo 只有 `ck`（`desiredKeys` 在 `ck.qry.af` 下），没有顶层的 `NotificationUserInfoKey.sessionId` / `approvalId` / `questionId`。正式版在 `BannerActionRunner.swift`、`Watch/WatchNotificationRouting.swift`、`PushRegistration.swift` 都读这些顶层 key。A-12 要在 NSE 里把 CK 字段或取回的记录写进 `content.userInfo` 的这几个 key（或让处理代码解析 `CKQueryNotification`）。collapse id 要等于 `NotificationIdentity.id(...)`（`<sessionID>-needs_approval` 这一类），ADR-0012 的 `PushCoverage` 才能匹配。
