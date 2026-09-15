# 关注任务：语音与手表优先提醒调研

日期：2026-09-12。研究基线：`b55bfaf674778864a91f427d1e8fa085e370c398`。
状态：研究完成；未实施、未运行设备实验、未提交或创建 PR。

## 需求与结论

用户希望关注任务在需要批准、需要回答、完成、失败时优先通过电脑语音和手表震动提醒。正在使用电脑不应压掉手表提醒；新增选项默认开启，手表提醒还应越过应用内勿扰和静音时段。电脑弹窗允许共存。系统勿扰是否可以穿透，是本研究的核心可行性问题。

**可以实现应用自己的提醒优先级，并通过用户允许的时效性通知或 Focus 应用白名单穿透系统勿扰；不能由一个默认开启的应用开关代替系统授权。** 手表静音本身允许震动，不需要 Critical Alerts。若还要求手机解锁时手表照样收到通知，应验证手表独立 APNs，而不是只修现有 iPhone 镜像链路。[A1][A2][A3][A4]

这里的“语音”按现有讨论理解为 Mac 播报，手表负责震动，不扩大为手表自动朗读。现有 Mac 自动朗读仅覆盖生成成功的完成摘要，尚不覆盖批准、提问和失败的短句播报；若最终要所有事件都有语音，这是另一个明确的实现增量。[C5]

## Apple 平台事实

| 问题 | 核实结果 | 对本功能的意义 |
|---|---|---|
| Mac 前台会不会必然阻止手表提醒？ | Apple 的 iPhone/Watch 转发规则依据两者锁定及佩戴状态；本项目另外施加了 Mac presence 过滤。[A1][C1] | 可移除关注任务的应用级远端过滤，不必改变 Mac 是否持有原生审批。 |
| 手表静音是否禁止震动？ | Silent Mode 保留允许的触觉通知；Theater Mode 也可保留。Focus/DND 会抑制提醒，除非设置例外。[A2] | 不要把系统静音、应用 Quiet 和系统 Focus 混为一谈。 |
| 普通应用能否穿透 Focus？ | Time Sensitive 可越过 Focus/通知摘要，但用户可关闭；Focus 也可按应用允许通知。[A3][A4] | 默认开启的是产品意愿；另需引导并检查系统权限，不能显示虚假的“已穿透”。 |
| 能否强制覆盖系统限制？ | Critical Alerts 需要 Apple entitlement 和用户授权；HIG 将其用于直接影响个人的紧急健康与安全信息。[A5][A6] | 编程会话提醒不能以必获特批为设计前提，也不能声称 Critical Alerts 是无条件送达保证。 |
| iPhone 解锁时镜像到手表吗？ | 可在两端出现的通知优先去亮屏解锁的 iPhone；否则去佩戴且解锁的 Watch，再否则回到 iPhone。[A1] | 仅解除 Mac 过滤无法满足“手机也在用，手表仍提醒”。 |
| 能直接给 Watch 发通知吗？ | watchOS 6 起可注册独立 token。转发文档明确：直接发给 Watch 的远程通知只在 Watch 出现；Watch 本地通知也只在该 Watch 出现。[A1][A7] | 手表直推有官方依据，应作为严格手表优先的候选。 |
| 手机和 Watch 同时发会怎样？ | 另一篇官方文档建议有 iOS companion 的应用可双发，系统会选最佳目的地并避免重复。[A7] | 不应从双发文档推出“直接发给 Watch 也一定被 iPhone 截走”；也不能把双发视为两端必响。 |
| 后台直接调用震动能否兜底？ | `WKInterfaceDevice.play` 在普通 background/inactive 状态无效，文档列出运动会话例外。[A8] | WatchConnectivity 收到数据再调用震动不能承担回到表盘后的即时提醒；不用无关运动会话伪装保活。 |

### 对前面口头结论的修正

“直接给手表发推送，系统仍一定会选择手机”过于笼统。完整文档区分了 **Watch-only 的投递目的地** 与 **companion 双发的系统协调**。研究建议验证 Watch 独立 token 的单独投递，随后再验证与 iPhone 同事件双发、先后发、镜像的实际协调结果。[A1][A7]

这不等于证明所有情况下必震：目的地、系统允许展示、用户实际感到震动是三个不同层次。当前没有在用户手表上测试这条独立路径。

### 时效性通知使用边界

HIG 要求内容值得立即关注，事件正在发生或将在一小时内发生。批准/回答等待与用户主动关注任务的即时完成/失败可作为本产品的候选；将后两者加入时效性通知是产品判断，不是 Apple 已审核认可的事实。启动工作、普通进度、历史会话及配额不随此功能一概升级。不要把周期性完成重提醒自动等同于首次时效性事件。[A6]

对于“这个 App 的提醒都允许穿透”的个人使用目标，在相应 Focus 中允许 VibeBuddy 是官方支持的直接办法；它按应用而非按会话授权，“仅关注任务”仍要由应用自己控制。[A4]

## 现有代码的阻断点

以下均为当前源码静态核对结果，不是运行或真机通过证据。

1. **事件被提前丢弃。** `SoundPolicy` 在 `appActive` 时不产生完成/失败边界通知；完成还有默认 30 秒运行门槛、首次快照静默、主动 Stop 排除及等待去抖。Quiet 将任务视为 muted，前台任务被压为 list。只在发送器里新增选项，不能找回已经丢掉的事件。[C1]
2. **远端复用 Mac 已降低的等级。** `MenuBarModel` 将 coordinator 返回的 alerts 交给 push；`PushFanout` 拒绝 list/drop，接收手机的 Quiet 还能再次降级。远端策略必须能独立于 Mac 本地呈现决定。[C2]
3. **完成通知没有声音请求，也不是 Time Sensitive。** `DeliveryMatrix` 的 followed completion 为 banner；`SoundAlert.isTimeSensitive` 仅对 bannerSound 的批准/提问成立。Mac APNs 和 iPhone 本地通知还受 `playSound` 影响。`sound` 缺失不能当作可验收的手表触觉契约，必须用真实 payload 对照测试。[C1][C3]
4. **目前手表没有独立 APNs 路径。** `VibeBuddyWatchApp` 注册的是镜像通知长视图；Watch entitlement 仅有 App Group，未配置 push/time-sensitive；iPhone 已有这两项。当前入口没有 Watch token 注册。开发账号实际能力和新签名 profile 尚未检查。[C4]
5. **现有手表主动震动只适用于前台。** `WatchStateStore.feel` 要求 `isForeground`，还服从 relay 的 Quiet/categories；触觉基于 dashboard 变化，不是逐条关注事件的独立投递账本。不能通过删掉前台 guard 解决平台后台限制。[C4][A8]
6. **Mac 语音同样被前台状态压制。** 朗读依赖本地 `onScheduled`、有效 completion summary、`isCurrentCompletion`；摘要生成、发送前验证及播放验证均有 Quiet/前台过滤。因此“电脑不弹窗但仍播报”不能只改手表策略，还需解除语音对本地弹窗成功的依赖。保留用户关闭朗读、语音通话中不抢音等现行约束。[C5]
7. **不能破坏已有去重及审批权限。** ADR-0012 的 phone receipt 仅证明手机路径已安排通知，不能证明 Watch 已提醒；加入 Watch 独立目的地后不能用它取消 Watch 发送。Mac presence 对 `answerable` 的决定与提醒无关，不能为了手表震动扩大审批权限。[C6][C7]

## 推荐方案与 PR 边界（拟议，未实施）

新增默认开启的 **“关注任务优先提醒”**。说明文案建议：“关注任务的手表提醒不受电脑使用状态和应用内勿扰时段影响。系统专注模式需允许 VibeBuddy 或时效性通知。”避免使用“强制穿透”或“保证震动”。

应用内优先规则针对有效关注状态；明确取消关注/任务 muted 不应被重新升级。已有类别关闭是否要覆盖，用户没有要求，建议继续尊重。关闭新选项后恢复旧投递策略。自动关注与手动关注是否都覆盖，应沿用 `effectiveAttention` 的项目定义并在实现说明中交代。[C1][C7]

事件先判定是否需要提醒，再分别决定 Mac 视觉、Mac 语音、手机/Watch 的投递。关注任务的远端提醒越过 Mac presence 和应用 Quiet；不要把所有通道一起调成最高等级。手机镜像仍可能让 iPhone 发声，不能把此路径宣传为仅手表震动。[C2][C3][A1]

**建议先用最小真机探针验证 Watch 独立 APNs，再定生产路由。** 注册 Watch token，直接向它发送一个有声的时效性提醒，验证 iPhone 解锁且 Watch 回到表盘时的表现。官方支持 Watch Push Notifications 和 Time Sensitive 能力，但本项目还需配置签名、token 注册/更新、按目标 topic 发送、前台 presentation，以及直接通知动作回到原会话的路径。[A7][A9][C4]

若探针通过，正式实现可将 Watch 作为独立目的地，复用用户控制的现有 APNs provider；手机及镜像兜底要按目标分别记账，验证双发不重复、旧 token 不吞提醒。没有“Watch 真正震动”回执时，不要用短超时宣称确切送达或确切失败。继续遵守 ADR-0013，不新建运营推送服务，不分发凭据。[C6]

若只修现有镜像链路，PR 可以解决“人在 Mac 前”和“应用 Quiet”过滤，但必须明确保留“手机亮屏时手表可能不提醒”的缺口。它不是完整实现严格的手表优先。

## 必须用设备回答的最小问题

| 实验 | 需要观察的结果 |
|---|---|
| Mac 正在显示真实关注任务；iPhone 锁屏；Watch 佩戴解锁并在表盘 | 批准/提问/完成/失败分别有对应 Watch 通知和可感到的震动；电脑语音按设置播放。 |
| 同上，但开启应用 Quiet 与静音时段 | 新选项开启不压掉 Watch 事件；关闭则回到旧策略。 |
| Watch 系统 Silent Mode | 通知仍有触觉，且无需让手表扬声器出声。对比当前无 sound payload 和有 sound payload。 |
| 系统 Focus：允许时效性／允许应用／两者均不允许 | 前两种配置分别验证；最后一种如被系统抑制，应准确说明，不报告穿透成功。 |
| iPhone 亮屏解锁，Watch 在表盘：Watch 单发与 companion 双发 | 确认直接目的地与系统去重的实际行为；记录通知可见和触觉，不仅记录 APNs 200。 |
| Watch App 前台，随后退回表盘 | 前台手动触觉与系统通知无重复；后台无需依靠进程保持活跃。 |
| 先手机本地通知回执，再发 Watch；反向顺序；重连 | 手机回执不会取消尚未提醒的 Watch；同一事件不会因重连反复震动。 |
| 从 Watch 通知打开及处理原会话 | 会话/本轮身份正确；read-only 等待仍不可远端批准；结果回到同一请求。 |

试验需新候选安装和用户触觉确认，本轮未执行。发行验收还须按现有 `docs/watch-notification-acceptance.md` 验证 TestFlight/production 环境，开发证据不代替发行证据。[C8]

研究已回答平台可行性与代码影响范围。剩余实质未知是 **用户设备上 Watch 单发/双发的呈现和触觉结果、系统授权状态、新签名配置**；没有源码阅读或网页能代替这些实验。研究不触发功能实施或发布。

## 来源

官方正文查阅于 2026-09-12；Apple Developer 动态页面同时读取其官方 `tutorials/data/documentation/...json` 正文，不只依据搜索摘要。

- [A1 — Taking advantage of notification forwarding](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding)，通知类型/来源/目的地表及锁定规则。
- [A2 — Silence notifications for extended periods on Apple Watch](https://support.apple.com/guide/watch/silence-notifications-for-extended-periods-apd41eadfc95/watchos)，模式比较表、Silent Mode 说明。
- [A3 — UNNotificationInterruptionLevel.timeSensitive](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive)，Discussion。
- [A4 — Allow or silence notifications for a Focus](https://support.apple.com/en-lamr/guide/iphone/-iph21d43af5b/ios)，按应用允许、Time Sensitive 设置。
- [A5 — Critical Alerts entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.critical-alerts)，权限与申请说明。
- [A6 — Managing notifications](https://developer.apple.com/design/human-interface-guidelines/managing-notifications)，Time Sensitive/Critical 适用范围及 watchOS 设置。
- [A7 — Enabling and receiving notifications](https://developer.apple.com/documentation/watchos-apps/enabling-and-receiving-notifications)，Watch token、前台委托、companion 发送策略表。
- [A8 — WKInterfaceDevice.play](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:))，后台调用限制。
- [A9 — Supported capabilities (watchOS)](https://developer.apple.com/help/account/reference/supported-capabilities-watchos)，Push Notifications、Time Sensitive Notifications。
- C1：[`SoundPolicy.swift`](../../VibeBuddyKit/Sources/VibeBuddyKit/SoundPolicy.swift)，`evaluate`、`completionSound`、`isTimeSensitive`；[`DeliveryMatrix.swift`](../../VibeBuddyKit/Sources/VibeBuddyKit/DeliveryMatrix.swift)。
- C2：[`PushFanout.swift`](../../VibeBuddyKit/Sources/VibeBuddyKit/PushFanout.swift)，`plan`；[`MenuBarModel.swift`](../../VibeBuddyMacApp/Sources/MenuBarModel.swift)，snapshot loop、`push`。
- C3：[`APNs.swift`](../../VibeBuddyMac/Sources/VibeBuddyMacCore/APNs.swift)，`alertPayload`；[`Notifier.swift`](../../VibeBuddyApp/Sources/Notifier.swift)，`post`；[`SoundPrefs.swift`](../../VibeBuddyApp/Sources/SoundPrefs.swift)。
- C4：[`VibeBuddyWatchApp.swift`](../../VibeBuddyApp/Watch/VibeBuddyWatchApp.swift)、[`WatchStateStore.swift`](../../VibeBuddyApp/Watch/WatchStateStore.swift) 的 `feel`、[`WatchHapticPlayer.swift`](../../VibeBuddyApp/Watch/WatchHapticPlayer.swift)、[`Watch entitlement`](../../VibeBuddyApp/Watch/VibeBuddyWatch.entitlements)、[`iPhone entitlement`](../../VibeBuddyApp/VibeBuddyApp.entitlements)。
- C5：[`MenuBarModel.swift`](../../VibeBuddyMacApp/Sources/MenuBarModel.swift)，`onScheduled`、`isCurrentCompletion`、`generateCompletionNotice`；[`ReadAloud.swift`](../../VibeBuddyMacApp/Sources/ReadAloud.swift)。
- C6：[`ADR-0012`](../adr/0012-one-banner-per-cue-phone-receipts.md)；[`ADR-0013`](../adr/0013-apns-key-delivery.md)，末尾 Decision。
- C7：[`CONTEXT.md`](../../CONTEXT.md)，Presence、SessionAttention、DeliveryMatrix、Read aloud。
- C8：[`Watch notification release acceptance`](../watch-notification-acceptance.md)。
